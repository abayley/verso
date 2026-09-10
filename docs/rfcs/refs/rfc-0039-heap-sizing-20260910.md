# RFC-0039 Heap Sizing (2026-09-10)

Supporting evidence for [RFC-0039](../implemented/rfc-0039-constant-space-document-handling.md), rollout step 8: the
measurements behind the `VERSO_HEAP_CELLS` default of 8,000,000 cells. Taken after steps 1 to 7 landed, on
the same machine and corpus as the memory profile, with `build/verso +RTS -H<cells> -RTS`.

## Heap Sizing Method

Each run started cold (the persisted link index deleted) against `cello-docs` (3980 documents, largest
263KB) with search off, recorded the link-index build time and RSS at "listening on", then fetched the
263KB document's editor page twelve times as three rounds of four concurrent requests and recorded RSS
again. A separate run used the search-demo corpus with search on: eight searches, then four concurrent
editor-page requests for the 46,000px document.

## Heap Sizing Results

| `-H` cells | heap bytes | cold build | RSS at ready | RSS after 12 edits | edits   |
| ---------- | ---------- | ---------- | ------------ | ------------------ | ------- |
| 4,000,000  | 61MB       | 18.0s      | 80MB         | 136MB              | all 200 |
| 6,000,000  | 92MB       | 11.6s      | 122MB        | 246MB              | all 200 |
| 8,000,000  | 122MB      | 9.7s       | 143MB        | 348MB              | all 200 |
| 16,000,000 | 244MB      | 7.7s       | 269MB        | not measured       |         |

No run exhausted the heap. Before step 5 the same cold build needed 8M cells (the memory profile's floor);
it now completes at 4M, where the GC-bound build takes 18s. RSS after the edits grows with the heap because
a larger arena collects less often, so more escaped-page buffers await the next sweep; the live set is
the same at every size.

Search on, 8M cells, search-demo corpus: startup 1.6s (search 0.9s), RSS 269MB at ready (the ONNX runtime's
shared code and mmap'd model account for most of it), 296MB after the searches and edits, no exhaustion.

## Heap Sizing Decision

8,000,000 cells. It is twice the size that survives everything measured, so normal use has headroom for
larger documents and more concurrency than the test applied, while the ceiling is 122MB against the
previous default's 244MB and the runtime's 763MB. The cost is startup: 9.7s against 7.7s for the cold
build of the real corpus, paid once. A reintroduced whole-file read of a large document (263KB unpacked
to a `String` is several million cells, transiently, per request) now competes for a heap this size under
concurrency instead of disappearing into a large one. Operators with unusually large documents or high
concurrency raise it on the `make run-verso` command line; 4M and 6M both work for a smaller footprint at
the price of a slower start.
