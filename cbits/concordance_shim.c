/* The real Concordance search shim (RFC-0034): ONNX Runtime C API for
 * embedding, the patched lancedb-c for the chunk store (vector + BM25 +
 * native hybrid with RRF), and nanoarrow to build and read Arrow C ABI
 * data so no Arrow structure ever crosses the MicroHs FFI boundary.
 *
 * Built by `make search-shim`; see concordance_shim.h for the contract and
 * concordance_stub.c for the no-dependency stand-in.
 *
 * Ownership notes (learned in the phase 0 spike, contrary to some upstream
 * header comments): lancedb execute functions consume their query, and
 * lancedb_query_result_to_arrow consumes the result; neither is freed
 * again here.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <onnxruntime/onnxruntime_c_api.h>
#include "nanoarrow/nanoarrow.h"
typedef struct LanceDBObjectStoreRegistry LanceDBObjectStoreRegistry;
#include <lancedb.h>
#include "concordance_shim.h"

#define TABLE_NAME "chunks"
#define REC_SEP '\x1e'
#define FIELD_SEP '\x1f'

static void fail(char *err, long errlen, const char *what, const char *detail) {
    if (err && errlen > 0) {
        snprintf(err, (size_t) errlen, "%s%s%s", what, detail ? ": " : "",
                 detail ? detail : "");
    }
}

long cn_available(void) { return 1; }

unsigned long long cn_content_fp(const char *bytes, long len) {
    unsigned long long h = 14695981039346656037ULL;
    for (long i = 0; i < len; i++) {
        h ^= (unsigned char) bytes[i];
        h *= 1099511628211ULL;
    }
    return h;
}

/* ---- embedding ---- */

static const OrtApi *ort;
static OrtEnv *ort_env;
static OrtSession *ort_session;
static OrtMemoryInfo *ort_mem;
static int ort_ninputs;
static int ort_pooling;
static int ort_dims;

long cn_embed_init(const char *model_path, long pooling, long dims,
                   long threads, char *err, long errlen) {
    ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    OrtStatus *st;
#define ORT_STEP(what, expr) \
    if ((st = (expr)) != NULL) { \
        fail(err, errlen, what, ort->GetErrorMessage(st)); \
        return -1; \
    }
    ORT_STEP("env", ort->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "concordance", &ort_env));
    OrtSessionOptions *opts;
    ORT_STEP("options", ort->CreateSessionOptions(&opts));
    ORT_STEP("threads", ort->SetIntraOpNumThreads(opts, (int) threads));
    ORT_STEP("session", ort->CreateSession(ort_env, model_path, opts, &ort_session));
    ort->ReleaseSessionOptions(opts);
    ORT_STEP("meminfo", ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &ort_mem));
    size_t n;
    ORT_STEP("inputs", ort->SessionGetInputCount(ort_session, &n));
#undef ORT_STEP
    ort_ninputs = (int) n;
    ort_pooling = (int) pooling;
    ort_dims = (int) dims;
    return 0;
}

long cn_embed(const long *ids64, long ntok_l, double *out) {
    if (!ort_session) return -1;
    int ntok = (int) ntok_l;
    int64_t shape[2] = {1, ntok};
    int64_t *ids = malloc((size_t) ntok * sizeof *ids);
    int64_t *mask = malloc((size_t) ntok * sizeof *mask);
    int64_t *types = calloc((size_t) ntok, sizeof *types);
    long rc = -2;
    for (int i = 0; i < ntok; i++) { ids[i] = ids64[i]; mask[i] = 1; }

    const char *names[] = {"input_ids", "attention_mask", "token_type_ids"};
    OrtValue *inputs[3] = {0, 0, 0};
    OrtValue *output = NULL;
    const int64_t *bufs[] = {ids, mask, types};
    for (int i = 0; i < ort_ninputs; i++)
        if (ort->CreateTensorWithDataAsOrtValue(
                ort_mem, (void *) bufs[i], (size_t) ntok * sizeof(int64_t), shape, 2,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[i]))
            goto done;

    const char *out_names[] = {"last_hidden_state"};
    if (ort->Run(ort_session, NULL, names, (const OrtValue *const *) inputs,
                 (size_t) ort_ninputs, out_names, 1, &output))
        goto done;

    float *hidden;
    if (ort->GetTensorMutableData(output, (void **) &hidden)) goto done;

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
    if (norm > 0)
        for (int d = 0; d < ort_dims; d++) out[d] /= norm;
    rc = 0;

done:
    if (output) ort->ReleaseValue(output);
    for (int i = 0; i < ort_ninputs; i++)
        if (inputs[i]) ort->ReleaseValue(inputs[i]);
    free(ids);
    free(mask);
    free(types);
    return rc;
}

void cn_embed_close(void) {
    if (ort_mem) { ort->ReleaseMemoryInfo(ort_mem); ort_mem = NULL; }
    if (ort_session) { ort->ReleaseSession(ort_session); ort_session = NULL; }
    if (ort_env) { ort->ReleaseEnv(ort_env); ort_env = NULL; }
}

/* ---- store ---- */

static LanceDBConnection *store_conn;
static LanceDBTable *store_table;
static int store_dims;

static void chunks_schema(struct ArrowSchema *schema) {
    ArrowSchemaInit(schema);
    ArrowSchemaSetTypeStruct(schema, 7);
    ArrowSchemaSetType(schema->children[0], NANOARROW_TYPE_STRING);
    ArrowSchemaSetName(schema->children[0], "page_id");
    ArrowSchemaSetType(schema->children[1], NANOARROW_TYPE_STRING);
    ArrowSchemaSetName(schema->children[1], "anchor");
    ArrowSchemaSetType(schema->children[2], NANOARROW_TYPE_INT32);
    ArrowSchemaSetName(schema->children[2], "seq");
    ArrowSchemaSetType(schema->children[3], NANOARROW_TYPE_STRING);
    ArrowSchemaSetName(schema->children[3], "text");
    ArrowSchemaSetTypeFixedSize(schema->children[4], NANOARROW_TYPE_FIXED_SIZE_LIST, store_dims);
    ArrowSchemaSetName(schema->children[4], "vector");
    ArrowSchemaSetType(schema->children[4]->children[0], NANOARROW_TYPE_FLOAT);
    ArrowSchemaSetType(schema->children[5], NANOARROW_TYPE_STRING);
    ArrowSchemaSetName(schema->children[5], "stat_fp");
    ArrowSchemaSetType(schema->children[6], NANOARROW_TYPE_STRING);
    ArrowSchemaSetName(schema->children[6], "content_fp");
}

long cn_store_open(const char *dir, long dims, char *err, long errlen) {
    store_dims = (int) dims;
    LanceDBConnectBuilder *cb = lancedb_connect(dir);
    if (!cb) { fail(err, errlen, "connect builder", dir); return -1; }
    store_conn = lancedb_connect_builder_execute(cb);
    if (!store_conn) { fail(err, errlen, "connect", dir); return -2; }
    store_table = lancedb_connection_open_table(store_conn, TABLE_NAME);
    if (!store_table) {
        /* first open: create the table empty and its indexes lazily on
         * first upsert (FTS index needs at least the schema) */
        struct ArrowSchema schema;
        chunks_schema(&schema);
        char *emsg = NULL;
        if (lancedb_table_create(store_conn, TABLE_NAME,
                                 (const FFI_ArrowSchema *) &schema, NULL,
                                 &store_table, &emsg)
            != LANCEDB_SUCCESS) {
            fail(err, errlen, "create table", emsg);
            if (emsg) lancedb_free_string(emsg);
            return -3;
        }
        schema.release(&schema);
        const char *fts_cols[] = {"text"};
        if (lancedb_table_create_fts_index(store_table, fts_cols, 1, NULL, &emsg)
            != LANCEDB_SUCCESS) {
            fail(err, errlen, "fts index", emsg);
            if (emsg) lancedb_free_string(emsg);
            return -4;
        }
    }
    return 0;
}

void cn_store_close(void) {
    if (store_table) { lancedb_table_free(store_table); store_table = NULL; }
    if (store_conn) { lancedb_connection_free(store_conn); store_conn = NULL; }
}

/* Advances past one NUL-terminated string in a packed buffer. */
static const char *next_str(const char **cursor) {
    const char *s = *cursor;
    *cursor += strlen(s) + 1;
    return s;
}

long cn_store_upsert(const char *page_id, const char *stat_fp,
                     const char *content_fp, long nchunks,
                     const char *anchors, const char *texts,
                     const double *vectors, char *err, long errlen) {
    if (!store_table) { fail(err, errlen, "store not open", NULL); return -1; }
    char *emsg = NULL;

    /* delete-then-add replaces the page's chunks whatever their old count */
    char predicate[4096];
    snprintf(predicate, sizeof predicate, "page_id = '%s'", page_id);
    if (lancedb_table_delete(store_table, predicate, &emsg) != LANCEDB_SUCCESS) {
        fail(err, errlen, "delete before upsert", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -2;
    }
    if (nchunks == 0) return 0;

    struct ArrowSchema schema;
    struct ArrowArray array;
    struct ArrowError aerr;
    chunks_schema(&schema);
    if (ArrowArrayInitFromSchema(&array, &schema, &aerr) != NANOARROW_OK
        || ArrowArrayStartAppending(&array) != NANOARROW_OK) {
        fail(err, errlen, "arrow init", NULL);
        return -3;
    }
    const char *acur = anchors;
    const char *tcur = texts;
    for (long r = 0; r < nchunks; r++) {
        ArrowArrayAppendString(array.children[0], ArrowCharView(page_id));
        ArrowArrayAppendString(array.children[1], ArrowCharView(next_str(&acur)));
        ArrowArrayAppendInt(array.children[2], r);
        ArrowArrayAppendString(array.children[3], ArrowCharView(next_str(&tcur)));
        for (int d = 0; d < store_dims; d++)
            ArrowArrayAppendDouble(array.children[4]->children[0],
                                   vectors[r * store_dims + d]);
        ArrowArrayFinishElement(array.children[4]);
        ArrowArrayAppendString(array.children[5], ArrowCharView(stat_fp));
        ArrowArrayAppendString(array.children[6], ArrowCharView(content_fp));
        if (ArrowArrayFinishElement(&array) != NANOARROW_OK) {
            fail(err, errlen, "arrow row", NULL);
            return -4;
        }
    }
    if (ArrowArrayFinishBuildingDefault(&array, &aerr) != NANOARROW_OK) {
        fail(err, errlen, "arrow finish", aerr.message);
        return -5;
    }
    LanceDBRecordBatchReader *reader = NULL;
    if (lancedb_record_batch_reader_from_arrow(
            (FFI_ArrowArray *) &array, (const FFI_ArrowSchema *) &schema,
            &reader, &emsg)
        != LANCEDB_SUCCESS) {
        fail(err, errlen, "batch reader", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -6;
    }
    schema.release(&schema);
    if (lancedb_table_add(store_table, reader, &emsg) != LANCEDB_SUCCESS) {
        fail(err, errlen, "table add", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -7;
    }
    return 0;
}

long cn_store_delete(const char *page_id, char *err, long errlen) {
    if (!store_table) { fail(err, errlen, "store not open", NULL); return -1; }
    char predicate[4096];
    snprintf(predicate, sizeof predicate, "page_id = '%s'", page_id);
    char *emsg = NULL;
    if (lancedb_table_delete(store_table, predicate, &emsg) != LANCEDB_SUCCESS) {
        fail(err, errlen, "delete", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -2;
    }
    return 0;
}

/* Appends one field (and separator) to the out buffer, escaping nothing:
 * the separators are non-printing and cannot occur in page text that came
 * through the chunker (control characters are not valid Markdown). */
static long put_field(char *out, long outlen, long pos, const char *s, char sep) {
    long len = (long) strlen(s);
    if (pos + len + 1 >= outlen) return -1;
    memcpy(out + pos, s, (size_t) len);
    out[pos + len] = sep;
    return pos + len + 1;
}

/* Walks the batches of a query result, appending page_id/anchor/seq/score/
 * text records (search) or page_id/stat_fp/content_fp records (pages). */
static long emit_records(LanceDBQueryResult *res, int want_text, char *out,
                         long outlen, char *err, long errlen) {
    struct FFI_ArrowArray **arrays = NULL;
    struct FFI_ArrowSchema *schema = NULL;
    size_t count = 0;
    char *emsg = NULL;
    if (lancedb_query_result_to_arrow(res, &arrays, &schema, &count, &emsg)
        != LANCEDB_SUCCESS) {
        fail(err, errlen, "result to arrow", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -1;
    }
    /* An empty result comes back with no batches -- and a NULL schema,
     * which must not be touched (phase 6 crash: NULL + n_children). */
    if (count == 0 || schema == NULL) {
        if (outlen > 0) out[0] = '\0';
        if (arrays) lancedb_free_arrow_arrays(arrays, count);
        if (schema) lancedb_free_arrow_schema(schema);
        return 0;
    }
    struct ArrowSchema *s = (struct ArrowSchema *) schema;
    int col_page = -1, col_anchor = -1, col_seq = -1, col_text = -1;
    int col_score = -1, col_stat = -1, col_content = -1;
    for (int c = 0; c < (int) s->n_children; c++) {
        const char *n = s->children[c]->name;
        if (strcmp(n, "page_id") == 0) col_page = c;
        if (strcmp(n, "anchor") == 0) col_anchor = c;
        if (strcmp(n, "seq") == 0) col_seq = c;
        if (strcmp(n, "text") == 0) col_text = c;
        if (strcmp(n, "_relevance_score") == 0 || strcmp(n, "_score") == 0
            || strcmp(n, "_distance") == 0)
            col_score = c;
        if (strcmp(n, "stat_fp") == 0) col_stat = c;
        if (strcmp(n, "content_fp") == 0) col_content = c;
    }
    if (col_page < 0 || (want_text && (col_anchor < 0 || col_seq < 0 || col_text < 0))
        || (!want_text && (col_stat < 0 || col_content < 0))) {
        lancedb_free_arrow_arrays(arrays, count);
        lancedb_free_arrow_schema(schema);
        fail(err, errlen, "result schema missing expected columns", NULL);
        return -4;
    }
    long nrec = 0;
    long pos = 0;
    for (size_t b = 0; b < count; b++) {
        struct ArrowArray *a = (struct ArrowArray *) arrays[b];
        struct ArrowArrayView view;
        struct ArrowError aerr;
        if (ArrowArrayViewInitFromSchema(&view, s, &aerr) != NANOARROW_OK
            || ArrowArrayViewSetArray(&view, a, &aerr) != NANOARROW_OK) {
            fail(err, errlen, "arrow view", NULL);
            return -2;
        }
        for (int64_t r = 0; r < a->length; r++) {
            char field[64];
            struct ArrowStringView sv;
#define PUT_STR(col, sep) \
    do { \
        sv = ArrowArrayViewGetStringUnsafe(view.children[col], r); \
        if (pos + sv.size_bytes + 1 >= outlen) goto full; \
        memcpy(out + pos, sv.data, (size_t) sv.size_bytes); \
        pos += sv.size_bytes; \
        out[pos++] = sep; \
    } while (0)
            PUT_STR(col_page, FIELD_SEP);
            if (want_text) {
                PUT_STR(col_anchor, FIELD_SEP);
                snprintf(field, sizeof field, "%lld",
                         (long long) ArrowArrayViewGetIntUnsafe(view.children[col_seq], r));
                if ((pos = put_field(out, outlen, pos, field, FIELD_SEP)) < 0) goto full;
                snprintf(field, sizeof field, "%.6f",
                         col_score >= 0
                             ? ArrowArrayViewGetDoubleUnsafe(view.children[col_score], r)
                             : 0.0);
                if ((pos = put_field(out, outlen, pos, field, FIELD_SEP)) < 0) goto full;
                PUT_STR(col_text, REC_SEP);
            } else {
                PUT_STR(col_stat, FIELD_SEP);
                PUT_STR(col_content, REC_SEP);
            }
#undef PUT_STR
            nrec++;
        }
        ArrowArrayViewReset(&view);
    }
    if (pos < outlen) out[pos] = '\0';
    lancedb_free_arrow_arrays(arrays, count);
    lancedb_free_arrow_schema(schema);
    return nrec;
full:
    lancedb_free_arrow_arrays(arrays, count);
    lancedb_free_arrow_schema(schema);
    fail(err, errlen, "result buffer full", NULL);
    return -3;
}

long cn_store_search(const double *query_vec, long dims,
                     const char *query_text, long k,
                     char *out, long outlen, char *err, long errlen) {
    if (!store_table) { fail(err, errlen, "store not open", NULL); return -1; }
    float *fvec = malloc((size_t) dims * sizeof *fvec);
    for (long d = 0; d < dims; d++) fvec[d] = (float) query_vec[d];
    LanceDBVectorQuery *vq = lancedb_vector_query_new(store_table, fvec, (size_t) dims);
    free(fvec);
    if (!vq) { fail(err, errlen, "vector query", NULL); return -2; }
    char *emsg = NULL;
    const char *cols[] = {"text"};
    if (lancedb_vector_query_full_text_search(vq, query_text, cols, 1, &emsg)
        != LANCEDB_SUCCESS) {
        fail(err, errlen, "fts component", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -3;
    }
    if (lancedb_vector_query_limit(vq, (size_t) k, &emsg) != LANCEDB_SUCCESS) {
        fail(err, errlen, "limit", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -4;
    }
    LanceDBQueryResult *res = lancedb_vector_query_execute_hybrid(vq);
    if (!res) { fail(err, errlen, "hybrid execute", NULL); return -5; }
    return emit_records(res, 1, out, outlen, err, errlen);
}

long cn_store_pages(char *out, long outlen, char *err, long errlen) {
    if (!store_table) { fail(err, errlen, "store not open", NULL); return -1; }
    LanceDBQuery *q = lancedb_query_new(store_table);
    if (!q) { fail(err, errlen, "query", NULL); return -2; }
    char *emsg = NULL;
    const char *cols[] = {"page_id", "stat_fp", "content_fp"};
    if (lancedb_query_select(q, cols, 3, &emsg) != LANCEDB_SUCCESS) {
        fail(err, errlen, "select", emsg);
        if (emsg) lancedb_free_string(emsg);
        return -3;
    }
    LanceDBQueryResult *res = lancedb_query_execute(q);
    if (!res) { fail(err, errlen, "execute", NULL); return -4; }
    return emit_records(res, 0, out, outlen, err, errlen);
}
