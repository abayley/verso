/* RFC-0034 phase 0 spike: the MicroHs-facing shim surface, minimal form.
 * Combines the ONNX embed path (from onnx/embed_spike.c) and a LanceDB
 * vector search (from store/store_spike.c) behind flat functions using only
 * scalars and caller-allocated buffers, plus a no-op for measuring raw FFI
 * call overhead from inside the MicroHs interpreter.
 *
 * Boundary types are int64/double because MicroHs marshals Int and Double
 * naturally; the shim converts to the int32/float the engines want.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <onnxruntime/onnxruntime_c_api.h>
#include "nanoarrow/nanoarrow.h"
typedef struct LanceDBObjectStoreRegistry LanceDBObjectStoreRegistry;
#include <lancedb.h>

/* ---- raw call overhead ---- */

long cn_noop(long x) { return x + 1; }

/* ---- embedding (ONNX Runtime C API) ---- */

static const OrtApi *ort;
static OrtEnv *ort_env;
static OrtSession *ort_session;
static OrtMemoryInfo *ort_mem;
static int ort_ninputs;
static int ort_pooling; /* 0 = mean, 1 = CLS */
static int ort_dims;

long cn_embed_init(const char *model_path, long pooling, long dims, long threads) {
    ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (ort->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "cn", &ort_env)) return -1;
    OrtSessionOptions *opts;
    if (ort->CreateSessionOptions(&opts)) return -2;
    if (ort->SetIntraOpNumThreads(opts, (int) threads)) return -3;
    if (ort->CreateSession(ort_env, model_path, opts, &ort_session)) return -4;
    ort->ReleaseSessionOptions(opts);
    if (ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &ort_mem)) return -5;
    size_t n;
    if (ort->SessionGetInputCount(ort_session, &n)) return -6;
    ort_ninputs = (int) n;
    ort_pooling = (int) pooling;
    ort_dims = (int) dims;
    return 0;
}

long cn_embed(const long *ids64, long ntok_l, double *out) {
    int ntok = (int) ntok_l;
    int64_t shape[2] = {1, ntok};
    int64_t *ids = malloc(ntok * sizeof *ids);
    int64_t *mask = malloc(ntok * sizeof *mask);
    int64_t *types = calloc(ntok, sizeof *types);
    for (int i = 0; i < ntok; i++) { ids[i] = ids64[i]; mask[i] = 1; }

    const char *names3[] = {"input_ids", "attention_mask", "token_type_ids"};
    OrtValue *inputs[3] = {0, 0, 0};
    const int64_t *bufs[] = {ids, mask, types};
    for (int i = 0; i < ort_ninputs; i++)
        if (ort->CreateTensorWithDataAsOrtValue(
                ort_mem, (void *) bufs[i], ntok * sizeof(int64_t), shape, 2,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[i]))
            return -1;

    const char *out_names[] = {"last_hidden_state"};
    OrtValue *output = NULL;
    if (ort->Run(ort_session, NULL, names3, (const OrtValue *const *) inputs,
                 ort_ninputs, out_names, 1, &output))
        return -2;

    float *hidden;
    if (ort->GetTensorMutableData(output, (void **) &hidden)) return -3;

    if (ort_pooling == 1) {
        for (int d = 0; d < ort_dims; d++) out[d] = hidden[d];
    } else {
        for (int d = 0; d < ort_dims; d++) out[d] = 0.0;
        for (int t = 0; t < ntok; t++)
            for (int d = 0; d < ort_dims; d++) out[d] += hidden[t * ort_dims + d];
        for (int d = 0; d < ort_dims; d++) out[d] /= ntok;
    }
    double norm = 0;
    for (int d = 0; d < ort_dims; d++) norm += out[d] * out[d];
    norm = sqrt(norm);
    if (norm > 0) for (int d = 0; d < ort_dims; d++) out[d] /= norm;

    ort->ReleaseValue(output);
    for (int i = 0; i < ort_ninputs; i++) ort->ReleaseValue(inputs[i]);
    free(ids);
    free(mask);
    free(types);
    return 0;
}

void cn_embed_close(void) {
    if (ort_mem) ort->ReleaseMemoryInfo(ort_mem);
    if (ort_session) ort->ReleaseSession(ort_session);
    if (ort_env) ort->ReleaseEnv(ort_env);
}

/* ---- store (lancedb-c) ---- */

static LanceDBConnection *store_conn;
static LanceDBTable *store_table;

long cn_store_open(const char *dir, const char *table_name) {
    LanceDBConnectBuilder *cb = lancedb_connect(dir);
    if (!cb) return -1;
    store_conn = lancedb_connect_builder_execute(cb);
    if (!store_conn) return -2;
    store_table = lancedb_connection_open_table(store_conn, table_name);
    if (!store_table) return -3;
    return 0;
}

/* Nearest-k by vector; returns hit count, writes the best distance. */
long cn_store_search(const double *vec, long dims_l, long k, double *best_distance) {
    int dims = (int) dims_l;
    float *fvec = malloc(dims * sizeof *fvec);
    for (int d = 0; d < dims; d++) fvec[d] = (float) vec[d];
    LanceDBVectorQuery *vq = lancedb_vector_query_new(store_table, fvec, dims);
    free(fvec);
    if (!vq) return -1;
    if (lancedb_vector_query_limit(vq, (size_t) k, NULL) != LANCEDB_SUCCESS) return -2;
    LanceDBQueryResult *res = lancedb_vector_query_execute(vq);
    if (!res) return -3;

    struct FFI_ArrowArray **arrays = NULL;
    struct FFI_ArrowSchema *schema = NULL;
    size_t count = 0;
    if (lancedb_query_result_to_arrow(res, &arrays, &schema, &count, NULL) != LANCEDB_SUCCESS)
        return -4;
    struct ArrowSchema *s = (struct ArrowSchema *) schema;
    int dist_col = -1;
    for (int c = 0; c < (int) s->n_children; c++)
        if (strcmp(s->children[c]->name, "_distance") == 0) dist_col = c;
    long hits = 0;
    *best_distance = -1;
    for (size_t b = 0; b < count; b++) {
        struct ArrowArray *a = (struct ArrowArray *) arrays[b];
        struct ArrowArrayView view;
        struct ArrowError e;
        if (ArrowArrayViewInitFromSchema(&view, s, &e) != NANOARROW_OK) return -5;
        if (ArrowArrayViewSetArray(&view, a, &e) != NANOARROW_OK) return -6;
        if (a->length > 0 && dist_col >= 0 && hits == 0)
            *best_distance = ArrowArrayViewGetDoubleUnsafe(view.children[dist_col], 0);
        hits += a->length;
        ArrowArrayViewReset(&view);
    }
    lancedb_free_arrow_arrays(arrays, count);
    lancedb_free_arrow_schema(schema);
    return hits;
}

void cn_store_close(void) {
    if (store_table) lancedb_table_free(store_table);
    if (store_conn) lancedb_connection_free(store_conn);
}
