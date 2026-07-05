/* Declarations for the MicroHs-facing search shim spike (cn_shim.c). */
#ifndef CN_SHIM_H
#define CN_SHIM_H

long cn_noop(long x);

long cn_embed_init(const char *model_path, long pooling, long dims, long threads);
long cn_embed(const long *ids, long ntok, double *out);
void cn_embed_close(void);

long cn_store_open(const char *dir, const char *table_name);
long cn_store_search(const double *vec, long dims, long k, double *best_distance);
void cn_store_close(void);

#endif
