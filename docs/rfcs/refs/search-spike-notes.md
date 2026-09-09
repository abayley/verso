# RFC-0034 Search Spike Notes

Phase 0 evidence for [RFC-0034](../implemented/rfc-0034-hybrid-search.md), gathered
2026-07-03/04 on macOS arm64 (M-series). Spike sources under `spike/search/`;
third-party builds under `vendor/search/` (git-ignored).

## ONNX Embedding Spike Results

Source: `spike/search/onnx/embed_spike.c` (ONNX Runtime C API, shaped like
the production `cn_embed_*` shim: token ids in, pooled + L2-normalised
vector out), driven by `compare.mjs` against reference vectors generated
with transformers.js (`spike/search/reference/embed-reference.mjs`).

ONNX Runtime installed via Homebrew (1.27.0); models pre-downloaded with
`curl` (the sandbox blocked bun's fetch to the HF LFS CDN, so the reference
generator runs with `env.localModelPath` offline).

### Embedding Correctness

Cosine similarity of the C shim's vectors against transformers.js fp32
reference, six probes (empty string to 15-word sentence), both candidate
models: **1.000000 on every probe**. The C API path with shim-side pooling
(mean for MiniLM, CLS for bge) and L2 normalisation exactly reproduces the
reference. PASS.

### Embedding Latency (ms per embed)

Single call, 20-rep average after warm-up, fp32 unless stated:

| Model               | Threads | 32 tok | 128 tok | 384 tok |
|---------------------|---------|--------|---------|---------|
| MiniLM fp32         | 1       | 7.9    | 31.7    | 108.2   |
| bge-small fp32      | 1       | 16.4   | 64.2    | 222.4   |
| bge-small fp32      | 4       | --     | --      | 56.5    |
| bge-small int8      | 1       | --     | --      | 109.5   |
| bge-small int8      | 4       | 2.3    | --      | 29.4    |
| MiniLM int8         | 4       | --     | --      | 13.7    |

Conclusions: the armchair 10-20 ms estimate holds for queries but not fp32
chunk embeds. With the quantised model and 4 intra-op threads the per-chunk
runtime stall is ~30 ms (bge) / ~14 ms (MiniLM) and a query embed is 2-3 ms.
The production shim should default to the quantised variant and expose the
intra-op thread count. Index and queries must use the same variant.

Quantisation drift (int8 vs fp32 reference, worst-case cosine over probes):
bge-small 0.9955, MiniLM 0.9817 -- comfortably within retrieval tolerance,
and another point to bge-small.

### Corpus A/B: bge-small vs MiniLM

`spike/search/reference/corpus-ab.mjs` sampled 306 pages (1 in 13) of the
real document tree into 1423 chunks (heading-split, title context line, as
per the RFC chunking decision), embedded them with both models (quantised),
and retrieved top-5 for eight realistic queries; the side-by-side report is
`spike/search/reference/corpus-ab-report.md` (not committed; regenerate
with the script). Judgement: **bge-small confirmed as default.** Its
neighbours stay on-topic (e.g. the ESL-battery query lands in spares/ESL
process pages) where MiniLM drifts entirely off-topic (ESG strategy, ESXi
BIOS), and its score distribution separates better. Caveat: with a 1-in-13
sample, the truly best page is often absent, so this is a relative
comparison, not a recall measurement.

### MicroHs FFI Spike Results

`spike/search/mhs/` builds a minimal production-shaped shim
(`cn_shim.c/h`: no-op, ONNX embed, LanceDB vector search; int64/double at
the boundary) and calls it from a MicroHs program (`FfiSpike.hs`) compiled
with `mhs -optl` linking. Findings:

- MicroHs FFI needs the declaring header named in the import string
  (`foreign import ccall "cn_shim.h cn_embed" ...`) and `-optc -I` for its
  include path; extra objects and libraries pass through `-optl`.
- Raw FFI call overhead: **~270 ns per call** -- negligible.
- Embed from inside the interpreter (bge-small int8, 4 threads): 2.8 ms at
  32 tokens, 28.7 ms at 384 tokens -- within noise of the C-side numbers
  (2.3 / 29.4 ms), so marshalling cost is irrelevant and the C-side cost
  model transfers directly.
- LanceDB vector search (k=2 over the spike dataset): 0.6 ms per call with
  correct results.

## lancedb-c Store Spike Results

Source: `spike/search/store/store_spike.c`. Built `lancedb-c` (main, no
tagged release; lancedb 0.30 / lance 7.0) with cargo; drove it through the
Arrow C ABI using only the **nanoarrow** 0.8.0 amalgamation -- no Arrow C++
anywhere. PASS for the vector path:

- connect, create table (`page_id` utf8, `text` utf8, `vector`
  `fixed_size_list<f32>`) from a nanoarrow-built record batch
- `lancedb_table_merge_insert` on `page_id` works as the idempotent upsert
- vector query ranks correctly and returns `_distance`
- FTS index creation on `text` succeeds (defaults)
- delete by SQL predicate; persistence verified across close/reopen

### lancedb-c Findings and Gaps

1. **No FTS query API upstream -- resolved by a small patch (2026-07-05).**
   Upstream `lancedb-c` can *create* an FTS index but exposes no way to run
   a match query. This is a wrapper gap, not an engine gap: the pinned
   `lancedb` 0.30 Rust crate contains `full_text_search`, a native
   `RRFReranker`, and `VectorQuery::execute_hybrid` (the same engine the
   TypeScript SDK's `.fullTextSearch().rerank()` chain calls). We patched
   `lancedb-c` (three functions: `lancedb_query_full_text_search`,
   `lancedb_vector_query_full_text_search`,
   `lancedb_vector_query_execute_hybrid`; ~380-line diff against upstream
   `36bb519`, kept at `spike/search/lancedb-c-fts-query.patch`) and proved
   through the spike harness:

   - BM25 FTS query returns ranked `_score` rows;
   - **FTS freshness: rows merge-inserted *after* index creation are
     immediately searchable with no optimize step** (Lance flat-scans
     unindexed rows), answering the RFC's freshness question;
   - native hybrid (vector + FTS with default RRF) returns
     `_relevance_score` rows with sensible fusion.

   The patch is PR-able upstream; until merged, the artefact build applies
   it to the pinned clone.
2. **Ownership bugs versus documentation.** The header says to free a query
   after execute and a result after `to_arrow`; doing either segfaults --
   execute and `to_arrow` consume their inputs. The production shim must
   follow the observed semantics, and this is worth an upstream issue.
3. **Header is not plain C.** `LanceDBObjectStoreRegistry` is referenced
   without a struct tag or typedef; compiling as C requires a forward
   typedef before including `lancedb.h` (their own tests are C++).
4. **FTS config sharp edge.** The `language` field wants tantivy-style
   names ("English"); ISO codes ("en") return InvalidArgument.
5. **Artefact size.** The release dylib is 223 MB (178 MB stripped) --
   the "one box" carries DataFusion and friends. Acceptable as a local
   cached artefact; not something to commit.
6. Build was clean on macOS arm64: cargo only (no protoc, no Arrow C++
   needed for the library itself), several minutes cold.

## Spike Status Against the RFC Phase 0 Gate

- ONNX embedding component: **go** (correctness exact, latency acceptable
  with quantised + threads).
- lancedb-c store component: **go** -- vector search, BM25 FTS, native
  hybrid with RRF, upsert, delete, persistence, and FTS freshness all
  proven through nanoarrow, with the caveat that FTS/hybrid ride on our
  ~380-line patch to lancedb-c until it is upstreamed (finding 1). Native
  hybrid also means `Concordance.Fuse` (Haskell RRF) demotes from default
  to fallback.
- MicroHs-to-shim call path: **go** -- ~270 ns raw call overhead, embed and
  search latencies indistinguishable from C, linking via `-optc`/`-optl`
  proven.
- Model choice: **bge-small-en-v1.5 confirmed** by the corpus A/B.

Phase 0 gate: **go on all components.** The lancedb-c FTS/hybrid patch is
prepared as an upstream PR (`spike/search/lancedb-c-pr.md`); until merged,
the artefact build applies `spike/search/lancedb-c-fts-query.patch` to the
pinned clone.
