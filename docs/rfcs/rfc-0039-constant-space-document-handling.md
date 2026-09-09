---
id: RFC-0039
name: Constant-space document handling and a fail-fast heap
status: Draft
owners:
    - Alistair Bayley
created: 2026-09-10
updated: 2026-09-10
supersedes: []
superseded_by: null
related_rfcs: [RFC-0014, RFC-0029]
related_refs:
    - docs/rfcs/refs/rfc-0039-memory-profile-20260910.md
---

# RFC-0039: Constant-space document handling and a fail-fast heap

## Summary

Make the server handle documents in space proportional to the work, not to document or corpus size, by
removing the paths that pull whole documents (or every document) into the MicroHs heap as `String` or as a
materialised list. Then set the MicroHs heap to a tight, fail-fast size, so that a future non-constant-space
regression crashes loudly at its introduction instead of silently inflating resident memory.

## Context

The MicroHs heap is a fixed, non-growable arena: `HEAP_CELLS` (default 50,000,000) 16-byte cells are
`malloc`'d once at startup (~763MB), the GC only marks and sweeps within it, and running out is a fatal
`heap exhausted`. It is set with `+RTS -H<cells> -RTS` and, because the arena is allocated before the config
file is read, cannot be a config key. RFC-0038's `VERSO_HEAP_CELLS` make variable already threads a tuned
value through `run-verso`.

Profiling (`docs/rfcs/refs/rfc-0039-memory-profile-20260910.md`) showed that the ~900MB resident a running
server reaches is that arena becoming resident under allocation churn, not the ONNX runtime (whose model is
mmap'd and whose code is shared). The churn comes from a few non-constant-space paths:

- `MicroHttp.Html.escapeBytes`/`escapeChars` unpack the whole content ByteString to a `String` to escape it,
  so embedding a document in the editor page costs roughly 190x the document size, transiently, per request.
- The link-index cold build folds over a fully materialised list of every document body, so the whole corpus
  is resident during startup.
- Frontmatter-title lookups unpack a whole document to read the small frontmatter block.
- Minor: a log-size check reads a whole file to measure its length; the operation log is read and unpacked
  whole.

HTTP body streaming (iteratees) and file serving (`sendfile`/`FileBody`, RFC-0014) are already
constant-space; this RFC extends that property to the document-rendering and indexing paths.

## Goals

- Rendering a document into a page uses memory proportional to the escaping work, not to the document size,
  with byte-identical output.
- Building or reloading the link index uses memory proportional to the index, not to the corpus, holding at
  most one document body at a time.
- Reading a document's frontmatter title touches only the frontmatter, not the whole document.
- After the above, `VERSO_HEAP_CELLS` defaults to a tight value chosen so the server survives normal
  operation with headroom but fails fast if a code path again reads a whole large file.
- No change to observable behaviour: same HTML bytes, same titles, same link index, same search results.

## Non-Goals

- Changing the MicroHs runtime or making its heap growable (that is upstream and out of scope).
- Reworking search embedding or lancedb (their memory lives in C, not the mhs heap).
- A general streaming-template engine. The escaper is the one hot renderer that needs fixing; the rest of
  the HTML builder stays as is.
- Moving document bytes off the heap entirely for editing. The editor legitimately needs the document in the
  response; the goal is to stop *multiplying* it, not to avoid sending it.

## Proposal

### Byte-level HTML escaping

Replace the `String` round-trip in `escapeBytes` (and `escapeChars`) with a byte-scanning escaper that never
materialises the input as a `String`. It emits the long unescaped runs between specials as `ByteString`
slices (O(1) views) and the five entities as small constant `ByteString`s, packing the result once so the
render stays a single builder chunk (composing thousands of builder nodes is itself a known mhs cost, so the
one-chunk property from the current code is preserved). The five specials are ASCII, and UTF-8 never places
an ASCII byte inside a multibyte sequence, so byte-level scanning is correct for UTF-8 content. The existing
`memchr` FFI used by `Verso.DocumentLinks` is the model for finding the next special quickly. A no-specials
input returns the input unchanged as one chunk.

### Streaming the link-index build

Change the cold build and reload so they walk the tree reading one document at a time, applying `updatePage`
and discarding the body, rather than materialising `[(PagePath, ByteString)]`. `LinkIndex.buildIndex` keeps
its meaning but is fed incrementally; the accumulated index (O(links)) is the only thing that grows. The
persisted-index reload path gets the same treatment.

### Frontmatter title without unpacking

Add a `ByteString`-level frontmatter-title reader that inspects only the leading frontmatter block (the
existing `SearchChunks.frontmatterSlice` already extracts it) and decodes just that small slice. Route
`breadcrumbsFor`, `readDocumentText`, `documentPageTitle`, and the `TreeMove` title lookup through it, so a
title lookup never unpacks the body. Where only the title is needed and the body is not already in hand,
read only the frontmatter head from disk rather than the whole file.

### Minor reads

`MicroHttp.Log` uses a `stat` size instead of reading a file to measure its length. `Verso.OperationLog`
parses the log over `ByteString` lines instead of `BS.unpack` of the whole file.

### Tight, fail-fast heap

Once the above land, lower the `VERSO_HEAP_CELLS` default to a value a little above the measured steady-state
working set (single-digit-million cells for the corpora measured), so the server runs comfortably in normal
use but a reintroduced whole-file read hits `heap exhausted` quickly and visibly rather than quietly using
hundreds of megabytes. The value stays overridable for operators with unusually large documents or high
concurrency.

## Alternatives Considered

- **Just set a tight heap now.** Rejected: with the non-constant-space paths still present, a tight heap
  crashes at startup on a large corpus (the link build) or on a large-document edit. The reads must be fixed
  first, which is the point of sequencing.
- **A C escaper via FFI.** A `cbits` escaper would be fully O(n) with no Haskell intermediate. Kept in
  reserve: the byte-slice approach in pure Haskell is expected to be enough and avoids growing the FFI
  surface; if benchmarks disagree, an FFI escaper is the fallback.
- **Escape into a `Builder` of per-special nodes.** Rejected: thousands of builder nodes are ~1ms each to
  force in mhs, so a special-heavy document would serialise in seconds. The one-chunk property is kept.
- **Leave rendering alone and only cut the heap that indexing needs.** Rejected: the per-request escaper
  spike is what makes concurrency dangerous (N concurrent large edits multiply the transient), so it is the
  more important fix.

## Security Impact

None intended. The escaper must stay byte-identical, so the set of escaped characters and their entities is
unchanged; a golden test pins this. No new inputs are trusted.

## Reliability Impact

The tight heap is the deliberate trade: a genuine non-constant-space path now crashes the server instead of
inflating memory. That is the intended fail-fast behaviour, but it means the default must be chosen with
headroom and stay overridable, and the largest documents and realistic concurrency must be exercised before
the default is lowered. Streaming the link build also removes a startup memory spike that scales with the
corpus.

## Compatibility Impact

No wire or on-disk format changes: same HTML, same persisted link index, same operation log. `run-verso`'s
default heap changes value in the final step; operators who set `VERSO_HEAP_CELLS` are unaffected.

## Testing and Quality Gates

- A golden test asserts the byte-scanning escaper is byte-identical to the current escaper across content
  with none, some, and many specials, including multibyte UTF-8 around specials.
- `make bench-html-builder` shows the escaper's time is no worse and its allocation materially lower;
  `make bench-link-parse` covers the link path.
- Link-index unit/integration tests still pass unchanged (same index for the same tree).
- Frontmatter-title tests (in `AppSpec`) still pass; add cases for a document whose body dwarfs its
  frontmatter to prove the body is not read.
- A guard that the server survives fetching the largest fixture document under a deliberately small heap,
  and that startup over a multi-document fixture does likewise.
- `make check` stays green throughout.

## Rollout Plan

Riskiest-value-first, each a small commit with `make check` green, the heap left generous until the end.

1. Byte-level escaper in `MicroHttp.Html`, with the golden test and the bench.
2. Frontmatter title on `ByteString`; route the callers through it.
3. Stream the link-index cold build and reload.
4. The minor reads (`Log` size via `stat`, `OperationLog` streaming parse).
5. Lower the `VERSO_HEAP_CELLS` default to the tight fail-fast value, after exercising the largest documents
   and realistic concurrency on the real corpus.

## Open Questions

- The exact tight default. The measured floor is single-digit-million cells for the corpora to hand, but the
  final number should come from the largest real documents plus a concurrency factor, decided in step 5.
- Whether a `cbits` escaper is needed, decided by the step-1 benchmark rather than up front.
- Whether the `TreeMove` asset copy (`BS.readFile >>= BS.writeFile`) is worth streaming; it is off the hot
  path and rare, so it is listed but not scheduled.
