/* RFC-0034 phase 0 spike: drive lancedb-c through the Arrow C ABI using
 * nanoarrow only (no Arrow C++), the way the production cn_store_* shim
 * would. Proves: connect, create table (utf8 + utf8 + fixed_size_list<f32>),
 * merge-insert (upsert), vector query, delete-by-predicate, persistence
 * across reopen, FTS index creation, BM25 FTS queries, FTS freshness after
 * upsert, and native hybrid (vector + FTS -> RRF) queries. The FTS/hybrid
 * query functions are our addition to lancedb-c (upstream exposes index
 * creation but no FTS query entry point); the patch is
 * spike/search/lancedb-c-fts-query.patch.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nanoarrow/nanoarrow.h"
/* lancedb.h compiles as C++ but not plain C: this type is referenced without
 * a struct tag or typedef (spike finding; upstream-fixable). */
typedef struct LanceDBObjectStoreRegistry LanceDBObjectStoreRegistry;
#include <lancedb.h>

#define DIMS 4

static void die(const char *what, char *err) {
    fprintf(stderr, "FATAL %s: %s\n", what, err ? err : "?");
    exit(1);
}
#define CHECK(what, expr) do { char *err_ = NULL; if ((expr) != LANCEDB_SUCCESS) die(what, err_); } while (0)
#define NA(what, expr) do { if ((expr) != NANOARROW_OK) die(what, NULL); } while (0)

/* chunks schema: page_id utf8, text utf8, vector fsl<f32, DIMS> */
static void make_schema(struct ArrowSchema *schema) {
    ArrowSchemaInit(schema);
    NA("struct", ArrowSchemaSetTypeStruct(schema, 3));
    NA("f0", ArrowSchemaSetType(schema->children[0], NANOARROW_TYPE_STRING));
    NA("n0", ArrowSchemaSetName(schema->children[0], "page_id"));
    NA("f1", ArrowSchemaSetType(schema->children[1], NANOARROW_TYPE_STRING));
    NA("n1", ArrowSchemaSetName(schema->children[1], "text"));
    NA("f2", ArrowSchemaSetTypeFixedSize(schema->children[2], NANOARROW_TYPE_FIXED_SIZE_LIST, DIMS));
    NA("n2", ArrowSchemaSetName(schema->children[2], "vector"));
    NA("f2c", ArrowSchemaSetType(schema->children[2]->children[0], NANOARROW_TYPE_FLOAT));
}

typedef struct { const char *page_id, *text; float vec[DIMS]; } Row;

static void make_batch(struct ArrowArray *array, const struct ArrowSchema *schema,
                       const Row *rows, int nrows) {
    struct ArrowError e;
    NA("init", ArrowArrayInitFromSchema(array, (struct ArrowSchema *) schema, &e));
    NA("start", ArrowArrayStartAppending(array));
    for (int r = 0; r < nrows; r++) {
        NA("pid", ArrowArrayAppendString(array->children[0], ArrowCharView(rows[r].page_id)));
        NA("txt", ArrowArrayAppendString(array->children[1], ArrowCharView(rows[r].text)));
        for (int d = 0; d < DIMS; d++)
            NA("f", ArrowArrayAppendDouble(array->children[2]->children[0], rows[r].vec[d]));
        NA("fsl", ArrowArrayFinishElement(array->children[2]));
        NA("row", ArrowArrayFinishElement(array));
    }
    NA("finish", ArrowArrayFinishBuildingDefault(array, &e));
}

static LanceDBRecordBatchReader *reader_for(const struct ArrowSchema *schema,
                                            const Row *rows, int nrows) {
    struct ArrowArray array;
    make_batch(&array, schema, rows, nrows);
    LanceDBRecordBatchReader *reader = NULL;
    char *err = NULL;
    if (lancedb_record_batch_reader_from_arrow(
            (FFI_ArrowArray *) &array, (const FFI_ArrowSchema *) schema, &reader, &err)
        != LANCEDB_SUCCESS)
        die("reader_from_arrow", err);
    return reader;                    /* array consumed per Arrow C ABI */
}

/* Prints page_id + _distance for each hit of a vector query result. */
static void show_hits(LanceDBQueryResult *result) {
    struct FFI_ArrowArray **arrays = NULL;
    struct FFI_ArrowSchema *schema = NULL;
    size_t count = 0;
    char *err = NULL;
    if (lancedb_query_result_to_arrow(result, &arrays, &schema, &count, &err) != LANCEDB_SUCCESS)
        die("to_arrow", err);
    struct ArrowSchema *s = (struct ArrowSchema *) schema;
    int pid_col = -1, score_col = -1;
    const char *score_name = "";
    for (int c = 0; c < (int) s->n_children; c++) {
        const char *n = s->children[c]->name;
        if (strcmp(n, "page_id") == 0) pid_col = c;
        if (strcmp(n, "_distance") == 0 || strcmp(n, "_score") == 0
            || strcmp(n, "_relevance_score") == 0) { score_col = c; score_name = n; }
    }
    for (size_t b = 0; b < count; b++) {
        struct ArrowArray *a = (struct ArrowArray *) arrays[b];
        struct ArrowArrayView view;
        struct ArrowError e;
        NA("viewinit", ArrowArrayViewInitFromSchema(&view, s, &e));
        NA("viewset", ArrowArrayViewSetArray(&view, a, &e));
        for (int64_t r = 0; r < a->length; r++) {
            struct ArrowStringView pid = ArrowArrayViewGetStringUnsafe(view.children[pid_col], r);
            double sc = score_col >= 0 ? ArrowArrayViewGetDoubleUnsafe(view.children[score_col], r) : -1;
            printf("  hit: %.*s  %s=%.4f\n", (int) pid.size_bytes, pid.data,
                   score_col >= 0 ? score_name : "(noscore)", sc);
        }
        ArrowArrayViewReset(&view);
        fprintf(stderr, "  [view reset ok]\n");
    }
    lancedb_free_arrow_arrays(arrays, count);
    fprintf(stderr, "  [arrays freed]\n");
    lancedb_free_arrow_schema(schema);
    fprintf(stderr, "  [schema freed]\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *dir = argc > 1 ? argv[1] : "/tmp/lancedb-spike";
    char uri[512];
    snprintf(uri, sizeof uri, "%s", dir);
    char *err = NULL;

    LanceDBConnectBuilder *cb = lancedb_connect(uri);
    LanceDBConnection *conn = lancedb_connect_builder_execute(cb);
    if (!conn) die("connect", NULL);
    printf("connected: %s\n", lancedb_connection_uri(conn));

    struct ArrowSchema schema;
    make_schema(&schema);

    /* create with 3 rows: unit-ish vectors along different axes */
    Row rows[] = {
        {"guides/a.md", "alpha wolf configuration", {1, 0, 0, 0}},
        {"guides/b.md", "beta badger failover",     {0, 1, 0, 0}},
        {"notes/c.md",  "gamma gopher timeout",     {0, 0, 1, 0}},
    };
    LanceDBTable *table = NULL;
    CHECK("create", lancedb_table_create(conn, "chunks", (const FFI_ArrowSchema *) &schema,
                                         reader_for(&schema, rows, 3), &table, &err_));
    printf("created table with 3 rows\n");

    /* upsert: replace page b's row via merge_insert on page_id */
    Row upsert[] = {{"guides/b.md", "beta badger REVISED failover", {0, 0.9f, 0.1f, 0}}};
    const char *on[] = {"page_id"};
    LanceDBMergeInsertConfig mcfg = {1, 1};
    CHECK("merge", lancedb_table_merge_insert(table, reader_for(&schema, upsert, 1),
                                              on, 1, &mcfg, &err_));
    printf("merge-insert (upsert) ok\n");

    /* vector query: nearest to b's new vector */
    float q[DIMS] = {0, 1, 0, 0};
    LanceDBVectorQuery *vq = lancedb_vector_query_new(table, q, DIMS);
    if (!vq) die("vq_new", NULL);
    CHECK("vq_limit", lancedb_vector_query_limit(vq, 2, &err_));
    LanceDBQueryResult *res = lancedb_vector_query_execute(vq);
    if (!res) die("vq_exec", NULL);
    printf("vector query (expect guides/b.md first):\n");
    show_hits(res);
    /* NOTE (spike finding): contrary to the header comments, the execute /
     * to_arrow chain consumes its inputs -- freeing the result after
     * to_arrow, or the query after execute, segfaults (double free). */

    /* FTS index creation (query entry point does not exist in lancedb-c) */
    /* NULL config = defaults; note the language field wants tantivy-style
     * names ("English"), not ISO codes ("en" -> InvalidArgument). */
    const char *fts_cols[] = {"text"};
    CHECK("fts_index", lancedb_table_create_fts_index(table, fts_cols, 1, NULL, &err_));
    printf("fts index created on text\n");

    /* FTS query (patched lancedb-c): "badger" should match guides/b.md */
    LanceDBQuery *fq = lancedb_query_new(table);
    if (!fq) die("fts_q_new", NULL);
    CHECK("fts_set", lancedb_query_full_text_search(fq, "badger", fts_cols, 1, &err_));
    CHECK("fts_lim", lancedb_query_limit(fq, 5, &err_));
    LanceDBQueryResult *fres = lancedb_query_execute(fq);
    if (!fres) die("fts_exec", NULL);
    printf("fts query 'badger' (expect guides/b.md):\n");
    show_hits(fres);

    /* FTS freshness: upsert a NEW page after index creation, no optimize */
    Row fresh[] = {{"notes/d.md", "delta dingo quokka burrow", {0.5f, 0.5f, 0, 0}}};
    CHECK("merge2", lancedb_table_merge_insert(table, reader_for(&schema, fresh, 1),
                                               on, 1, &mcfg, &err_));
    LanceDBQuery *fq2 = lancedb_query_new(table);
    CHECK("fts_set2", lancedb_query_full_text_search(fq2, "quokka", fts_cols, 1, &err_));
    LanceDBQueryResult *fres2 = lancedb_query_execute(fq2);
    if (!fres2) die("fts_exec2", NULL);
    printf("fts freshness: 'quokka' upserted AFTER index, no optimize (expect notes/d.md):\n");
    show_hits(fres2);

    /* hybrid: vector near c's axis + text 'badger'; RRF should surface both */
    float hq[DIMS] = {0, 0, 1, 0};
    LanceDBVectorQuery *hvq = lancedb_vector_query_new(table, hq, DIMS);
    if (!hvq) die("hy_new", NULL);
    CHECK("hy_fts", lancedb_vector_query_full_text_search(hvq, "badger", fts_cols, 1, &err_));
    CHECK("hy_lim", lancedb_vector_query_limit(hvq, 4, &err_));
    LanceDBQueryResult *hres = lancedb_vector_query_execute_hybrid(hvq);
    if (!hres) die("hy_exec", NULL);
    printf("hybrid query vec~notes/c.md + fts 'badger' (expect c and b on top, RRF):\n");
    show_hits(hres);

    /* delete by predicate */
    CHECK("delete", lancedb_table_delete(table, "page_id = 'notes/c.md'", &err_));
    printf("delete by predicate ok\n");

    /* persistence: reopen and count via plain query */
    lancedb_table_free(table);
    table = lancedb_connection_open_table(conn, "chunks");
    if (!table) die("reopen", NULL);
    LanceDBQuery *all = lancedb_query_new(table);
    LanceDBQueryResult *allres = lancedb_query_execute(all);
    if (!allres) die("scan", NULL);
    printf("reopened; remaining rows:\n");
    show_hits(allres);

    schema.release(&schema);
    lancedb_table_free(table);
    lancedb_connection_free(conn);
    printf("OK\n");
    return 0;
}
