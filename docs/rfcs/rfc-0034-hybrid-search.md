---
id: RFC-0034
name: Hybrid Search With Embeddings, Full-Text, and LanceDB
status: Draft
owners:
    - alistairbayley
created: 2026-07-03
updated: 2026-07-03
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Hybrid Search With Embeddings, Full-Text, and LanceDB

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-07-03       |
| Started   |                  |
| Completed |                  |

## Summary

Add hybrid search over the document tree: semantic search via sentence
embeddings combined with BM25 full-text search, fused into one ranked result
list. Embeddings are computed in-process with the ONNX Runtime C API running
a small BERT-family sentence-embedding model (default `bge-small-en-v1.5`,
384-dim, 512-token window; the model is a configured profile, not a
constant), with the BERT WordPiece tokeniser implemented in pure Haskell. Storage and retrieval use LanceDB through the
official `lancedb-c` bindings, hidden behind a small project-owned C shim
(using `nanoarrow` internally) so MicroHs only ever sees flat C functions
over scalars and buffers. The index is maintained by an in-process,
coalescing re-index queue drained by a green thread, with startup
reconciliation for crash recovery. The engine (embedding, store, fusion) is
a separate library under `Concordance.*`, depending on neither
`MicroHttp.*` nor `Verso.*`; chunking, queue wiring, and the search endpoint
are Verso code.

## Context

- `TODO.md` lists "embedding-based search" as a backend goal.
- The corpus today is small (hundreds to low thousands of pages, so roughly
  5k-50k chunks), but the engine should be reusable over corpora of various
  sizes. That motivates a real vector store with ANN capability and built-in
  full-text search over a hand-rolled flat-file scan that only works at the
  small end. LanceDB provides vector search, BM25 full-text search, and
  hybrid ranking in one embedded store.
- LanceDB publishes official C bindings
  ([lancedb-c](https://github.com/lancedb/lancedb-c)). They are young (no
  tagged releases yet) and exchange data via the Arrow C ABI, which MicroHs
  FFI cannot consume directly. Every existing `foreign import` in this
  project is a static `ccall` to a plain function over scalars and pointers;
  there are no dynamic imports and no callbacks.
- The ONNX Runtime C API is official and stable, but it is exposed as a
  struct of function pointers (`OrtGetApiBase()`), which MicroHs cannot call
  through. A C shim is therefore required for embedding regardless of any
  other choice, which satisfies the decision register's "C helpers only when
  direct imports cannot work" bar (ADR-004).
- HuggingFace `tokenizers` is Rust with official Python/Node bindings only.
  The candidate models (`bge-small-en-v1.5`, `gte-small`,
  `all-MiniLM-L6-v2`, `snowflake-arctic-embed-xs`) all use plain BERT
  WordPiece over a fixed `vocab.txt` (30,522 entries), which is small
  enough to implement and test directly -- and keeps the tokeniser valid
  across the candidate set.
- MicroHs runs green threads on a cooperative scheduler; a blocking C call
  stalls every thread in the runtime. This is why the socket layer is
  non-blocking throughout. A single query-time embed (~10-20 ms) is an
  acceptable stall; embedding a whole corpus in one call is not.
- Precedents this design leans on: RFC-0029 (persisted index, refresh-based
  freshness, ByteString-native processing, measured cost models), RFC-0028
  (operation log as the record of tree mutations), `MicroHttp.Process`
  (subprocess escape hatch), RFC-0030 (framework/application split).

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Hybrid (semantic + full-text) search over all pages, exposed as a Verso
  endpoint and a search box in the editor shell.
- One embedding path shared by indexing and queries.
- Index stays close to fresh under normal operation: publish, move,
  delete, restore, and rollback re-index affected pages asynchronously
  without freezing the server.
- Engine reusable outside Verso and outside MicroHttp: `Concordance.*` is
  its own library namespace with no dependency on `MicroHttp.*` or
  `Verso.*`, taking paths, loggers, and config as explicit parameters.
- `make check` continues to pass on machines with no Rust toolchain, no
  ONNX Runtime, and no model files; search is a build-and-run optional
  feature.

## Non-Goals

- ANN index tuning (IVF/HNSW parameters). Exact search is fine at current
  scale; LanceDB makes ANN available later without an API change.
- Search UI beyond a basic query box and result list (ranking explanations,
  filters, facets, snippets beyond chunk text).
- Cross-encoder reranking, query rewriting, or multiple embedding models.
- GPU execution providers for ONNX Runtime.
- Embedding anything other than page Markdown (no attachments, no images).
- Windows support for the shim (matches the current socket portability
  posture: RFC-0007 remains open).

## Proposal

### Architecture

```text
Verso.App (handlers)
  |  enqueue pages on publish/move/delete/restore/rollback
  v
Verso.SearchIndex (chunker, queue, worker, reconcile)   [Verso.*]
  |  chunks + queries
  v
Concordance.Embedding  -- WordPiece (pure Haskell) + embed via C shim
Concordance.Store      -- upsert/delete/search via C shim
Concordance.Fuse       -- reciprocal rank fusion (pure Haskell)
  |
  v
cbits/concordance_shim.{c,h}  -- our C shim: ONNX Runtime C API + lancedb-c
                                 + nanoarrow; exposes flat functions only
  |
  v
libonnxruntime.dylib/.so    +    liblancedb_c.dylib/.so
```

### Key Decisions

0. **The engine is a separate library, `Concordance.*`.** Search does not
   need HTTP; nothing in the engine belongs to the web framework. A
   concordance is the book trade's index of every word and where it
   occurs -- precisely this artefact -- and the name sits alongside Verso's
   bookish naming. Alternatives: `MicroSearch` (family convention, but the
   library is not part of the Micro* toolchain lineage); `Embedding` is too
   narrow (the library also owns the store, full-text search, and fusion);
   `Search` is generic and hard to grep. Dependency rule, extending
   RFC-0030: `Verso.*` may depend on `MicroHttp.*` and `Concordance.*`;
   `Concordance.*` depends on neither, and `MicroHttp.*` does not depend on
   `Concordance.*`. Source lives at `src/Concordance/` in this repository.
1. **LanceDB through `lancedb-c`, wrapped in a project C shim.** The "one
   box" property (vector + BM25 + hybrid, incremental upserts, persistence,
   scales past brute force) is worth the build-chain weight. The Arrow C ABI
   never crosses the FFI boundary: the shim uses `nanoarrow` (Apache's small
   C library for the Arrow C data interface) to build and unpack record
   batches, and exposes only flat functions to MicroHs. Full Arrow C++ is
   explicitly avoided.
2. **Embedding in-process via the ONNX Runtime C API.** The same
   `Concordance.Embedding` path serves indexing and queries; using the
   same model, pooling, and prefixes for both is a correctness requirement.
   Pooling (mean or CLS, per the model profile) and L2 normalisation happen
   in the shim, so Haskell receives a final unit vector.
3. **WordPiece tokeniser in pure Haskell.** Lowercase, accent strip,
   punctuation split, greedy longest-match against `vocab.txt`, `[CLS]` /
   `[SEP]` and attention mask. Pure, unit-testable against reference
   tokenisations generated once with transformers.js (a `scripts/` generator
   writes the fixture file; the test suite never runs JS).
4. **In-process re-index queue drained by a green thread.** The worker takes
   one page at a time: read, chunk, then for each chunk embed (one blocking
   FFI call) and yield to the scheduler before the next. A large move smears
   its cost over time as ~10-20 ms stutters instead of a freeze. The queue is
   a coalescing pending-set keyed by page id: enqueueing an already-pending
   page is a no-op; re-enqueueing a page whose re-index is in flight marks it
   dirty so it is processed again. Upserts are idempotent (delete all chunks
   for the page id, insert fresh), so a publish racing an in-flight re-index
   of the same page resolves on the next drain.
5. **Freshness by reconciliation, not queue durability, with a two-tier
   fingerprint.** The store records per page both a *stat fingerprint*
   (path, mtime, size -- the link index's cheap kind) and a *content
   fingerprint* (FNV-1a 64 over the raw Markdown bytes, computed in the C
   shim to avoid the MicroHs per-byte-fold trap; change detection only, no
   cryptographic claim). On startup (and on `POST /index/refresh`,
   alongside the link index), reconcile walks stats first; only pages whose
   stat changed are read and content-hashed; only pages whose content
   fingerprint changed are enqueued for re-embedding, and the stored stat
   is silently refreshed for the rest. Pages missing from the store are
   enqueued; store entries for pages gone from the tree are deleted. So a
   migration-era re-export that rewrote every mtime but changed three pages
   costs one tree read and three re-embeds -- hashing is orders of
   magnitude cheaper than embedding. A crash mid-queue costs a catch-up,
   never correctness. The two reconcile moments differ deliberately: at
   startup the reconcile is stat-tier only (the link index reloads its
   persisted state without reading the tree, and search matches that
   cheapness); on explicit `POST /index/refresh` the link index rebuild
   already reads every page's bytes, and the search reconcile piggybacks
   its content hashing on that same read pass. "Index refresh" is one
   action over all derived indexes; its response reports what it did (link
   index rebuilt; N pages enqueued for re-indexing). Embedding always
   stays asynchronous in the worker -- refresh never blocks on it.
6. **Hybrid ranking with reciprocal rank fusion, native.** The Phase 0
   spike proved native hybrid queries (vector + BM25, engine-side RRF by
   default) through our lancedb-c patch, so the shim exposes one hybrid
   search call and `Concordance.Fuse` (pure Haskell RRF) demotes to a
   fallback seam rather than the default path. RRF avoids calibrating
   incompatible score scales either way. The patch
   (`spike/search/lancedb-c-fts-query.patch`) is applied to the pinned
   lancedb-c clone by the artefact build until upstreamed.
7. **Chunking by heading section with a token cap.** A chunk is a heading
   section (the RFC-0026/0029 machinery already understands page structure);
   sections longer than the chunk cap (~384 tokens under the default
   model's 512-token window -- retrieval granularity degrades past this
   regardless of window size) split at paragraph boundaries. Each chunk
   records page path, heading anchor, sequence number, and text, so a
   result can deep-link to the section. No overlap in the first version.
   A chunk's stored text serves FTS, embedding input, and the result
   excerpt alike: a context line -- the page title (frontmatter `name`)
   plus ancestor heading path -- followed by the section's Markdown with
   frontmatter stripped and code/Mermaid fences kept (fence content is
   exactly what an ops wiki's full-text queries look for). Embedding
   truncates at the token cap; FTS sees the full text, so titles are
   full-text searchable with no separate title column. Accepted trade-off:
   excerpts show the context line and raw Markdown syntax; the result
   renderer can soften that later.
8. **Search is optional at build and run time.** The shim and its libraries
   build via dedicated make targets (`make search-shim`), never as part of
   `make check`. At startup Verso enables search only when
   `VERSO_SEARCH_ENABLED` is true and the shim, model, and vocab paths
   resolve; otherwise the search endpoint returns a clear "search not
   enabled" response and the queue is inert.
9. **Model files are fetched, not committed.** `make search-model` downloads
   the ONNX model (quantised variant, tens of MB) and `vocab.txt` from
   HuggingFace into a local cache directory; config points at them.
10. **`lancedb-c` is consumed as a prebuilt cached artefact.** Building it
    needs the full Rust toolchain, so that build happens once per platform
    (`make search-lancedb`, requiring Rust + CMake) and the resulting dylib
    lands in a git-ignored artefact cache (Makefile `SEARCH_LIB_DIR`,
    default `vendor/search/<platform>/`). Day-to-day builds and `make
    search-shim` link against the cached artefact and need only a C
    compiler. The project C shim itself always builds from source -- it is
    a single small C file.
11. **Query embedding stays on the request path, with a small cache.** A
    search request pays one blocking embed (~10-20 ms), which is
    acceptable. The Verso search handler keeps a small LRU of recent query
    text to query vector, so repeated and refined queries skip the embed;
    the engine itself stays stateless.
12. **Search reflects published state only.** Drafts live outside the
    document tree, are never served, and never enter the index -- the same
    contract the link index holds. The enqueue hooks are the actions that
    change published content or tree structure: publish, move, delete,
    restore, and rollback. An author's unpublished draft text is not
    findable until published, matching what the read view shows.
13. **The embedding model is a configured profile, not a constant.** The
    profile is `{model path, vocab path, max tokens, pooling mode, query
    prefix, dimensions}`. Default: `bge-small-en-v1.5` (384-dim, 512-token
    window, CLS pooling) -- measurably better retrieval than
    `all-MiniLM-L6-v2` at near-identical cost; MiniLM is the named fallback
    if the Phase 0 A/B sanity check on real corpus queries disagrees.
    Embeddings from different models are incommensurable, so the store
    records the model id as dataset metadata; on open, a mismatch with the
    configured profile marks the whole index invalid and reconcile performs
    a full rebuild.
14. **Moves and deletes cascade to three page populations.** A page's
    identity is its tree path, and a move rewrites more than the moved
    item: (1) every page under the moved item gets `delete(old path)` plus
    `enqueue(new path)`; (2) every referrer whose links were rewritten is
    enqueued (the move handler already computes this set from the link
    index); (3) the affected parent sections' `index.md` listings are
    enqueued (their bodies changed). Recursive section delete removes every
    store entry under the old prefix (Verso enumerates them from the
    store's page listing) and enqueues rewritten referrers and listings.
    Deferred optimisation, explicitly out of v1: re-keying moved rows
    without re-embedding when the content fingerprint is unchanged -- a
    large section move therefore re-embeds its pages in the background,
    accepted because large moves are migration-era.
15. **Partial results with disclosure.** Search serves whatever is indexed
    from the moment it is enabled; whenever the re-index queue is
    non-empty, the result fragment carries an "indexing in progress -- N
    pages pending" note, so an incomplete answer is never silent. Worker
    failures (the parked failed set) are an operator concern and stay in
    the log for v1.

### C Shim Interface (sketch)

```c
/* embedding; pooling: 0 = mean, 1 = CLS (from the model profile) */
int  cn_embed_init(const char *model_path, int pooling, int dims,
                   char *err, int errlen);
int  cn_embed(const int32_t *ids, const int32_t *mask, int ntokens,
              float *out384, char *err, int errlen);
void cn_embed_close(void);

/* content fingerprint (FNV-1a 64; change detection, not security) */
uint64_t cn_content_fp(const uint8_t *bytes, int len);

/* store */
int  cn_store_open(const char *dir, char *err, int errlen);
int  cn_store_upsert(const char *page_id, const char *fingerprint,
                     const cn_chunk *chunks, int nchunks,
                     char *err, int errlen);
int  cn_store_delete(const char *page_id, char *err, int errlen);
int  cn_store_search(const float *query384, const char *query_text,
                     int k, cn_hit *hits, char *err, int errlen);
int  cn_store_pages(cn_page_fp *out, int cap, char *err, int errlen);
void cn_store_close(void);
```

Fixed-size out-parameters and caller-allocated buffers throughout; no
callbacks, no ownership transfer across the boundary. Tokenisation happens
in Haskell, so `cn_embed` takes token ids, not text.

### Data Model

One Lance table, `chunks`:

| Column       | Type     | Notes                                            |
|--------------|----------|--------------------------------------------------|
| `page_id`    | utf8     | tree path, e.g. `guides/setup.md`                |
| `anchor`     | utf8     | heading anchor, empty for preamble               |
| `seq`        | int32    | chunk order within the page                      |
| `text`       | utf8     | chunk Markdown text (FTS-indexed)                |
| `vector`     | f32[384] | unit vector (vector-indexed)                     |
| `stat_fp`    | utf8     | per-page stat fingerprint, same on all rows      |
| `content_fp` | utf8     | per-page content fingerprint, same on all rows   |

### Query Flow

`GET /search?q=...`: tokenise and embed the query (one blocking embed,
~10-20 ms, skipped on a hit in the query-vector LRU), run vector + FTS (or
native hybrid) with k=20 each, fuse with RRF, group hits by page keeping
the best chunk per page, and render an htmx result fragment (page title,
heading anchor link, chunk excerpt), including the pending-count note when
the re-index queue is non-empty. The endpoint is read-only.

### Configuration

Application keys (all `VERSO_` overlayable, per `Verso.Config`):

- `search.enabled` (default false)
- `search.model` (path to ONNX model file)
- `search.vocab` (path to vocab.txt)
- `search.index-dir` (Lance dataset directory, default under the state dir)
- `search.model-id` (profile name recorded in the store; mismatch on open
  invalidates the index)
- `search.pooling`, `search.max-tokens`, `search.query-prefix`,
  `search.dims` (model profile knobs; defaults match `bge-small-en-v1.5`)

Engine modules receive these as parameters; only Verso reads config.

## Alternatives Considered

- **SQLite FTS5 + flat-file vectors + brute-force C scan.** Fewer moving
  parts, `sqlite3` is likely callable via direct `ccall` with no shim, and
  it is sufficient at current corpus scale. Rejected because the goal is a
  general engine across corpus sizes: past the small end this path grows
  its own ANN project, and hybrid plumbing that LanceDB already provides.
  It remains the documented fallback if Phase 0 kills the LanceDB path.
- **Sidecar process (bun + transformers.js, optionally LanceDB JS).** Zero
  C/FFI work and the Xenova model is packaged for exactly this runtime, but
  it makes bun and node_modules runtime dependencies and adds process
  supervision to the server. Kept as the escape hatch if in-process ONNX
  proves unstable.
- **Custom Rust cdylib wrapping the `lancedb` crate directly.** Full API
  access, but we would own an async-runtime-embedding Rust project;
  `lancedb-c` is the same idea maintained upstream.
- **Arrow C++ instead of nanoarrow in the shim.** Rejected: a very large
  dependency for building and unpacking small record batches.
- **Pure-Haskell everything (tokeniser, inverted index, vector scan).**
  RFC-0029's measured experience says large numeric/text sweeps in
  interpreted MicroHs are minefields; embedding is impossible in-process
  without ONNX anyway.

## Security Impact

- The search endpoint is read-only and renders result text through the
  existing HTML-escaping response builders; query text must be escaped like
  any other user input.
- No new authentication surface (the server has none yet; search inherits
  whatever RFC introduces it).
- The shim links two third-party native libraries that parse model and
  index files from disk. Both paths come from local config, not requests.
  Malformed files can crash the process (see Reliability); they cannot be
  supplied remotely.
- `make search-model` downloads from HuggingFace over HTTPS; the Makefile
  pins exact file URLs and records expected SHA-256 checksums.

## Reliability Impact

- **In-process native code can kill the server.** A segfault in ONNX
  Runtime, LanceDB, or our shim takes the whole process down, unlike the
  pure-Haskell status quo. Mitigations: the shim is small and
  valgrind-tested in its own harness; search is optional and off by
  default; the sidecar/subprocess design is the documented fallback if
  instability shows up in practice.
- **Queue loss on crash** is recovered by startup reconciliation
  (fingerprint sweep). Staleness window: from a mutation until the worker
  drains it, normally seconds.
- **Worker failures** (embed or upsert errors) log via the request-logging
  seam with the page id, retry once, then park the page id in a failed set
  reported in the log; the next reconcile retries it.
- **Index corruption** is recovered by deleting the dataset directory and
  re-running reconcile (full rebuild); document this in the runbook section
  of the design notes.
- **Scheduler stalls**: every FFI call in the worker loop is bounded (one
  chunk embed, one small upsert batch) with an explicit yield between
  calls. The spike must measure worst-case call durations so the stutter
  budget is a number, not a hope.

## Compatibility Impact

- macOS and Linux only, matching the current runtime posture.
- `make check` is unaffected: no new toolchain requirements. New make
  targets (`search-shim`, `search-model`) require CMake + a C compiler +
  Rust (for building `lancedb-c` once) and network access respectively.
- No changes to existing endpoints or the application stream contract; one
  new route plus queue hooks inside existing mutation handlers.
- `Concordance.*` is a new top-level library namespace; the `MicroHttp`
  facade and the RFC-0031 import conventions are untouched. The RFC-0030
  dependency rules extend to: `Verso.*` may depend on `MicroHttp.*` and
  `Concordance.*`; `Concordance.*` depends on neither.

## Testing and Quality Gates

- `make check` (unchanged gate) plus targeted suites below.
- Unit tests (no I/O, milliseconds): tokeniser against reference fixtures,
  chunker, RRF fusion, queue state machine (pure transitions).
- Integration tests (filesystem/FFI): shim round-trips, store persistence,
  end-to-end index-then-search on a tiny fixture tree. These are skipped
  with a clear message when the shim or model is absent, so the gate stays
  green on machines without the optional toolchain.
- The shim gets its own C-level test harness run under valgrind in
  `make search-shim-check` (not part of `make check`).

## Rollout Plan

### Phase 0: Spikes and Decision Gate

Compile-and-call evidence in `spike/search/`, with measurements recorded in
`docs/design/search-spike-notes.md`. No production code.

- [x] Spike: build `lancedb-c` as a dylib; from a C harness create a
      dataset, upsert rows with a vector column, run a vector query and an
      FTS query; record whether FTS sees new rows without an explicit
      optimize step, and whether a native hybrid/RRF query is exposed.
      RESULT: fully proven via nanoarrow (create, merge-insert upsert,
      ranked vector query, delete, persistence). Upstream lancedb-c had no
      FTS query API (index creation only); we patched it -- three C
      functions over the engine's existing `full_text_search` /
      `execute_hybrid` (`spike/search/lancedb-c-fts-query.patch`, PR-able)
      -- after which BM25 FTS, **native hybrid with default RRF**, and
      **FTS freshness (new rows searchable immediately, no optimize)** are
      all demonstrated. Findings and measurements in
      [search-spike-notes.md](../design/search-spike-notes.md).
- [x] Spike: minimal shim + MicroHs program calling it end-to-end
      (open, upsert, search, close) to prove the FFI shape and measure
      call latencies from inside the interpreter.
      RESULT: go. ~270 ns raw call overhead; embed and vector-search
      latencies from inside the interpreter match the C-side numbers
      (28.7 vs 29.4 ms per 384-token embed; 0.6 ms per search). Import
      convention and `-optc`/`-optl` linking recorded in the spike notes.
- [x] Spike: ONNX Runtime C API shim embedding a fixed token sequence;
      compare output vector against a transformers.js reference (cosine
      > 0.999); measure embed latency for 32/128/384-token inputs.
      RESULT: cosine 1.000000 on all probes, both models. Latency requires
      the quantised model + 4 intra-op threads to hit the budget: ~30 ms
      per 384-token chunk (bge-small int8), 2-3 ms per query embed. The
      shim defaults to the quantised variant and exposes the thread count.
      Measurements in
      [search-spike-notes.md](../design/search-spike-notes.md).
- [x] Spike: A/B sanity check `bge-small-en-v1.5` against
      `all-MiniLM-L6-v2` on a handful of real corpus queries (fall back to
      MiniLM if bge-small does not win).
      RESULT: bge-small confirmed as default -- on-topic neighbours where
      MiniLM drifts off-topic, better score separation, smaller
      quantisation drift (0.9955 vs 0.9817).
- [x] Decision gate: record go/no-go per component in this RFC. If
      `lancedb-c` fails (build, API gaps, instability), fall back to the
      SQLite FTS5 + flat vectors alternative and revise this RFC before
      continuing.
      RESULT: **go on all components** (2026-07-05). The one gap found --
      no FTS query API in upstream lancedb-c -- is closed by our patch,
      prepared as an upstream PR (`spike/search/lancedb-c-pr.md`); the
      artefact build applies the patch until it merges. Full evidence in
      [search-spike-notes.md](../design/search-spike-notes.md).

### Phase 1: WordPiece Tokeniser (pure Haskell)

Test cases, simplest to most complex, all against generated reference
fixtures:

- [x] given an empty string, when tokenised, then ids are `[CLS] [SEP]`
      with matching attention mask
- [x] given a single in-vocab lowercase word, when tokenised, then the
      expected single token id appears between the specials
- [x] given mixed case and accented input, when normalised, then output
      matches the reference (lowercase, accents stripped)
- [x] given punctuation adjacent to words, when tokenised, then
      punctuation splits into its own tokens
- [x] given an out-of-vocab word, when tokenised, then greedy
      longest-match produces `##` continuation pieces matching the
      reference
- [x] given a word with no matching pieces, when tokenised, then `[UNK]`
      (plus: mid-word match failure yields one `[UNK]` for the whole word,
      and words over 100 characters are `[UNK]` without matching)
- [x] given input longer than the profile's token cap, when tokenised,
      then truncation to the cap preserves `[SEP]`
- [x] given a vocabulary entry stored as multi-byte UTF-8, when the
      decoded character is encoded, then it matches (vocab lines are
      UTF-8-decoded on load)
- [x] Implementation: `Concordance.WordPiece` (vocab load is the only IO,
      injected as a `ByteString`); fixture generator
      `spike/search/reference/wordpiece-fixtures.mjs` (needs the spike's
      transformers.js install, so it lives beside it); integration spec
      replays 11 committed reference probes (real vocab, genuine HF
      tokeniser output) and all reproduce exactly.

### Phase 2: Chunker (pure)

- [ ] given a page with no headings, when chunked, then one preamble chunk
      with empty anchor and seq 0, prefixed by the title context line and
      with frontmatter stripped
- [ ] given a page with heading sections, when chunked, then one chunk per
      section carrying its anchor and order, each prefixed by title plus
      ancestor heading path (not its own heading)
- [ ] given a section containing code and Mermaid fences, when chunked,
      then fence content is preserved in the chunk text
- [ ] given a section exceeding the token cap, when chunked, then it
      splits at paragraph boundaries and seq stays contiguous
- [ ] given the same content, when content-fingerprinted twice, then
      fingerprints match; when content changes, then they differ; a
      stat-only change (touch) leaves the content fingerprint unchanged
- [ ] Implementation: `Verso.SearchChunks` reusing the tree/heading
      machinery from RFC-0026/0029.

### Phase 3: Embedding Seam

- [ ] Integration: given the shim and model, when embedding a known token
      sequence, then the vector matches the Phase 0 reference within
      tolerance and is L2-normalised
- [ ] Integration: given a closed embedder, when embed is called, then a
      typed error is returned (no crash)
- [ ] Implementation: shim `cn_embed_*`, `Concordance.Embedding`
      combining WordPiece + FFI with an injected shim seam so unit tests
      can fake it.

### Phase 4: Store Seam

- [ ] Integration: given an empty store, when a page is upserted and
      vector-searched with its own vector, then its chunks rank first
- [ ] Integration: given an upserted page, when FTS-searched for a term in
      its text, then the chunk is returned
- [ ] Integration: given a re-upserted page, when searched, then stale
      chunks are gone (idempotent replace)
- [ ] Integration: given a deleted page, when searched, then no hits
- [ ] Integration: given a store reopened after close, when pages are
      listed, then fingerprints survive (persistence)
- [ ] Implementation: shim `cn_store_*`, `Concordance.Store`.

### Phase 5: Hybrid Fusion

- [ ] given two ranked lists with a shared member, when fused with RRF,
      then the shared member outranks single-list members with equal ranks
- [ ] given an empty list on one side, when fused, then the other side's
      order is preserved
- [ ] given per-page grouping, when multiple chunks of one page hit, then
      the page appears once with its best chunk
- [ ] Implementation: `Concordance.Fuse` (pure); wire native hybrid
      instead if Phase 0 proved it.

### Phase 6: Re-Index Queue

- [ ] given an empty queue, when a page is enqueued twice, then it drains
      once (coalescing)
- [ ] given a page in flight, when it is re-enqueued, then it drains again
      after completion (dirty marking)
- [ ] given a drain step, when it completes, then the observable step
      result records page id, chunk count, and outcome (worker is a pure
      state machine around injected effects)
- [ ] Integration: given a running server, when a page is published, then
      within the drain interval a search finds its new content
- [ ] Integration: given a moved section, when the queue drains, then
      old-path entries are gone, new-path entries are searchable, and a
      rewritten referrer page has been re-indexed
- [ ] Integration: given a deleted section, when the queue drains, then no
      entries remain under its prefix
- [ ] Implementation: `Verso.SearchIndex` queue + worker green thread with
      per-chunk yield; enqueue hooks in the publish, move, delete, restore,
      and rollback handlers.

### Phase 7: Endpoint, Reconcile, and UI

- [ ] Integration: given indexed fixture pages, when `GET /search?q=` runs,
      then the fragment lists pages ranked by fusion with anchor links
- [ ] Integration: given search disabled, when the endpoint is hit, then a
      clear "not enabled" response returns
- [ ] Integration: given a non-empty re-index queue, when a search runs,
      then the fragment carries the pending count; when the queue drains,
      then the note disappears
- [ ] Integration: given a corpus edited out-of-band, when reconcile runs
      (startup and `POST /index/refresh`), then stale pages re-index and
      orphan index entries are removed
- [ ] UI: search box in the editor shell, leaning towards the top of the
      right sidebar above Contents (browser-first per AGENTS.md; placement
      settled by iteration, tests only for the interaction contract once
      stable)
- [ ] Implementation: `Verso.App` route, config keys, reconcile wired next
      to the link-index refresh.

### Phase 8: Documentation and Decisions

- [ ] ADRs: LanceDB-behind-shim decision, in-process embedding decision,
      queue/reconcile freshness model (extending ADR-067's story)
- [ ] Module index entries; README feature mention; runbook notes
      (rebuild-from-scratch procedure) in `docs/design/`
- [ ] Mark RFC implemented; move to `docs/rfcs/implemented/`

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts
  do not cover, stop changing the affected scope before inventing a
  contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- FTS analyser configuration: stemming and stop-word behaviour for the
  wiki's mixed prose/code content -- defaults first, revisit with real
  queries.
- Whether the search results render as a full page, a sidebar panel, or
  both (the box itself leans towards sitting above the Contents list;
  settled during Phase 7 browser-first iteration).
