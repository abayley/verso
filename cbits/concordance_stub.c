/* The no-dependency stand-in for the Concordance shim: linked when
 * `make search-shim` has not produced the real one, so the server builds
 * everywhere and search reports itself unavailable at runtime. The content
 * fingerprint is real (pure C); everything else fails cleanly.
 */
#include <string.h>
#include "concordance_shim.h"

static void say_unavailable(char *err, long errlen) {
    if (err && errlen > 0) {
        strncpy(err, "search shim not built (make search-shim)", (size_t) errlen - 1);
        err[errlen - 1] = '\0';
    }
}

long cn_available(void) { return 0; }

unsigned long long cn_content_fp(const char *bytes, long len) {
    unsigned long long h = 14695981039346656037ULL;
    for (long i = 0; i < len; i++) {
        h ^= (unsigned char) bytes[i];
        h *= 1099511628211ULL;
    }
    return h;
}

long cn_embed_init(const char *model_path, long pooling, long dims,
                   long threads, char *err, long errlen) {
    (void) model_path; (void) pooling; (void) dims; (void) threads;
    say_unavailable(err, errlen);
    return -1;
}

long cn_embed(const long *ids, long ntok, double *out) {
    (void) ids; (void) ntok; (void) out;
    return -1;
}

void cn_embed_close(void) {}

long cn_store_open(const char *dir, long dims, char *err, long errlen) {
    (void) dir; (void) dims;
    say_unavailable(err, errlen);
    return -1;
}

void cn_store_close(void) {}

long cn_store_upsert(const char *page_id, const char *stat_fp,
                     const char *content_fp, long nchunks,
                     const char *anchors, const char *texts,
                     const double *vectors, char *err, long errlen) {
    (void) page_id; (void) stat_fp; (void) content_fp; (void) nchunks;
    (void) anchors; (void) texts; (void) vectors;
    say_unavailable(err, errlen);
    return -1;
}

long cn_store_delete(const char *page_id, char *err, long errlen) {
    (void) page_id;
    say_unavailable(err, errlen);
    return -1;
}

long cn_store_search(const double *query_vec, long dims,
                     const char *query_text, long k,
                     char *out, long outlen, char *err, long errlen) {
    (void) query_vec; (void) dims; (void) query_text; (void) k;
    (void) out; (void) outlen;
    say_unavailable(err, errlen);
    return -1;
}

long cn_store_pages(char *out, long outlen, char *err, long errlen) {
    (void) out; (void) outlen;
    say_unavailable(err, errlen);
    return -1;
}
