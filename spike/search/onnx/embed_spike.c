/* RFC-0034 phase 0 spike: embed token sequences with the ONNX Runtime C API,
 * shaped like the production cn_embed_* shim will be: flat functions, token
 * ids in, one pooled + L2-normalised vector out.
 *
 * Protocol (stdin/stdout, driven by compare.mjs):
 *   line 1: <pooling:mean|cls> <dims>
 *   then per probe: <ntokens> followed by ntokens input ids (whitespace)
 *   EOF ends. For each probe, prints dims floats on one line.
 * With -bench N, instead embeds synthetic inputs of N tokens 20 times and
 * prints per-call milliseconds.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <onnxruntime/onnxruntime_c_api.h>

static const OrtApi *ort;

static void die(const char *what, OrtStatus *st) {
    fprintf(stderr, "FATAL %s: %s\n", what, st ? ort->GetErrorMessage(st) : "?");
    exit(1);
}
#define CHECK(what, expr) do { OrtStatus *st_ = (expr); if (st_) die(what, st_); } while (0)

typedef struct {
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *mem;
    int n_inputs;               /* 2 or 3 (token_type_ids present?) */
    int dims;
    int pooling;                /* 0 = mean, 1 = cls */
} Embedder;

static void embedder_init(Embedder *e, const char *model_path, int pooling, int dims) {
    ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    CHECK("env", ort->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "spike", &e->env));
    OrtSessionOptions *opts;
    CHECK("opts", ort->CreateSessionOptions(&opts));
    const char *threads_env = getenv("ORT_THREADS");
    CHECK("threads", ort->SetIntraOpNumThreads(opts, threads_env ? atoi(threads_env) : 1));
    CHECK("session", ort->CreateSession(e->env, model_path, opts, &e->session));
    ort->ReleaseSessionOptions(opts);
    CHECK("mem", ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &e->mem));
    size_t n;
    CHECK("ninputs", ort->SessionGetInputCount(e->session, &n));
    e->n_inputs = (int) n;
    e->dims = dims;
    e->pooling = pooling;
}

/* Embed one token sequence; writes dims floats (pooled, L2-normalised). */
static void embed(Embedder *e, const int64_t *ids, int ntok, float *out) {
    int64_t shape[2] = {1, ntok};
    int64_t *mask = malloc(ntok * sizeof *mask);
    int64_t *types = calloc(ntok, sizeof *types);
    for (int i = 0; i < ntok; i++) mask[i] = 1;

    const char *names3[] = {"input_ids", "attention_mask", "token_type_ids"};
    OrtValue *inputs[3] = {0, 0, 0};
    const int64_t *bufs[] = {ids, mask, types};
    for (int i = 0; i < e->n_inputs; i++)
        CHECK("input", ort->CreateTensorWithDataAsOrtValue(
            e->mem, (void *) bufs[i], ntok * sizeof(int64_t), shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[i]));

    const char *out_names[] = {"last_hidden_state"};
    OrtValue *output = NULL;
    CHECK("run", ort->Run(e->session, NULL, names3, (const OrtValue *const *) inputs,
                          e->n_inputs, out_names, 1, &output));

    float *hidden;                       /* [1, ntok, dims] */
    CHECK("outdata", ort->GetTensorMutableData(output, (void **) &hidden));

    if (e->pooling == 1) {               /* CLS */
        memcpy(out, hidden, e->dims * sizeof(float));
    } else {                             /* mean over attended tokens */
        for (int d = 0; d < e->dims; d++) out[d] = 0.0f;
        for (int t = 0; t < ntok; t++)
            for (int d = 0; d < e->dims; d++) out[d] += hidden[t * e->dims + d];
        for (int d = 0; d < e->dims; d++) out[d] /= ntok;
    }
    double norm = 0;
    for (int d = 0; d < e->dims; d++) norm += (double) out[d] * out[d];
    norm = sqrt(norm);
    if (norm > 0) for (int d = 0; d < e->dims; d++) out[d] /= (float) norm;

    ort->ReleaseValue(output);
    for (int i = 0; i < e->n_inputs; i++) ort->ReleaseValue(inputs[i]);
    free(mask);
    free(types);
}

static void bench(Embedder *e, int ntok) {
    int64_t *ids = malloc(ntok * sizeof *ids);
    ids[0] = 101;                        /* [CLS] */
    for (int i = 1; i < ntok - 1; i++) ids[i] = 2000 + (i % 20000);
    ids[ntok - 1] = 102;                 /* [SEP] */
    float *out = malloc(e->dims * sizeof *out);
    embed(e, ids, ntok, out);            /* warm-up */
    struct timespec t0, t1;
    const int reps = 20;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < reps; r++) embed(e, ids, ntok, out);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = ((t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6) / reps;
    printf("%d tokens: %.1f ms/embed\n", ntok, ms);
    free(ids);
    free(out);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s model.onnx <mean|cls> <dims> [-bench ntok]\n", argv[0]);
        return 2;
    }
    Embedder e;
    embedder_init(&e, argv[1], strcmp(argv[2], "cls") == 0 ? 1 : 0, atoi(argv[3]));
    fprintf(stderr, "model inputs: %d\n", e.n_inputs);

    if (argc >= 6 && strcmp(argv[4], "-bench") == 0) {
        bench(&e, atoi(argv[5]));
        return 0;
    }
    int ntok;
    float *out = malloc(e.dims * sizeof *out);
    while (scanf("%d", &ntok) == 1 && ntok > 0) {
        int64_t *ids = malloc(ntok * sizeof *ids);
        for (int i = 0; i < ntok; i++)
            if (scanf("%lld", (long long *) &ids[i]) != 1) { fprintf(stderr, "bad ids\n"); return 1; }
        embed(&e, ids, ntok, out);
        for (int d = 0; d < e.dims; d++) printf("%.8f ", out[d]);
        printf("\n");
        fflush(stdout);
        free(ids);
    }
    free(out);
    return 0;
}
