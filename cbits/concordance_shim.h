/* The Concordance search shim (RFC-0034): flat C functions over the ONNX
 * Runtime C API and lancedb-c, shaped for MicroHs FFI (scalars, pointers,
 * caller-allocated buffers; int64/double at the boundary).
 *
 * Two implementations share this header: concordance_shim.c (the real one,
 * requiring ONNX Runtime and the patched lancedb-c dylib; built by
 * `make search-shim`) and concordance_stub.c (no dependencies, every
 * function fails cleanly; linked when the shim has not been built, so the
 * server builds and runs everywhere with search disabled).
 *
 * Conventions: functions returning long yield >= 0 on success and < 0 on
 * failure; `err` buffers (when present) receive a NUL-terminated message.
 * Search hit and page listings are written into caller buffers as records
 * separated by 0x1e with fields separated by 0x1f.
 */
#ifndef CONCORDANCE_SHIM_H
#define CONCORDANCE_SHIM_H

/* Returned by cn_store_search and cn_store_pages when the out buffer is
 * too small for the full result; the caller may retry with a larger
 * buffer. Concordance.Store mirrors this value. */
#define CN_BUFFER_FULL (-9)

/* 1 when the real shim is linked, 0 for the stub. */
long cn_available(void);

/* FNV-1a 64 content fingerprint (works in both implementations). */
unsigned long long cn_content_fp(const char *bytes, long len);

/* Embedding. pooling: 0 = mean, 1 = CLS. */
long cn_embed_init(const char *model_path, long pooling, long dims,
                   long threads, char *err, long errlen);
long cn_embed(const long *ids, long ntok, double *out);
void cn_embed_close(void);

/* Store. */
long cn_store_open(const char *dir, long dims, char *err, long errlen);
void cn_store_close(void);

/* Replaces all of a page's chunks. anchors/texts: nchunks NUL-terminated
 * strings back to back; vectors: nchunks * dims doubles. */
long cn_store_upsert(const char *page_id, const char *stat_fp,
                     const char *content_fp, long nchunks,
                     const char *anchors, const char *texts,
                     const double *vectors, char *err, long errlen);

long cn_store_delete(const char *page_id, char *err, long errlen);

/* Compacts fragments, prunes old versions, and folds fresh rows into the
 * vector and FTS indexes. Cheap; called by the worker per the
 * optimisation policy (drain or batch). */
long cn_store_optimize(char *err, long errlen);

/* Hybrid search (vector + BM25, engine RRF). Writes up to k records of
 * page_id, anchor, seq, score, text into out. Returns the hit count. */
long cn_store_search(const double *query_vec, long dims,
                     const char *query_text, long k,
                     char *out, long outlen, char *err, long errlen);

/* Lists indexed pages: records of page_id, stat_fp, content_fp (each page
 * appearing once per chunk; callers dedupe). Returns the record count. */
long cn_store_pages(char *out, long outlen, char *err, long errlen);

#endif
