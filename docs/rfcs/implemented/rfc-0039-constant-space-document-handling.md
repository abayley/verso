---
id: RFC-0039
name: Constant-space document handling and a fail-fast heap
status: Implemented
owners:
    - Alistair Bayley
created: 2026-09-10
updated: 2026-09-10
supersedes: []
superseded_by: null
related_rfcs: [RFC-0014, RFC-0029]
related_refs:
    - docs/rfcs/refs/rfc-0039-memory-profile-20260910.md
    - docs/rfcs/refs/rfc-0039-escaper-bench-20260910.md
    - docs/rfcs/refs/rfc-0039-heap-sizing-20260910.md
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
- Streaming the *response* body of the editor page itself; the framework already streams file bodies, and
  the page is built as one chunk by design (RFC-0013).

## Proposal

### Byte-level HTML escaping

Replace the `String` round-trip in `escapeBytes` with a byte-level escaper that never materialises the
input as a `String`. The five specials are ASCII, and UTF-8 never places an ASCII byte inside a multibyte
sequence, so byte-level escaping is correct for UTF-8 content. The escaper is a small C function in the
framework's `cbits` (`microhttp_html.c`): one call computes the escaped length, a second writes the escaped
bytes into a private buffer that is packed into the result, so memory is the input plus the output and
the render stays a single builder chunk (composing thousands of builder nodes is itself a known mhs cost).
A no-specials input is returned as-is, without a copy.

Because it writes a buffer, `Html.escapeBytes :: ByteString -> IO Escaped` is an `IO` function, in line
with ADR-0086, which reserves `unsafePerformIO` for read-only scans. `Escaped` is opaque: the only way to
obtain one is to escape, and the view takes one (`Html.escapedText`) rather than raw bytes, so the type
says the content is safe to emit. The three handlers that build the editor page already read the document
in `IO` and escape it there. The `String` escaper (`escapeChars`, for attribute values and `text`) is
unchanged: its input is already a list, so it has no blowup to remove.

The RFC originally proposed a pure Haskell scan driven by `memchr` with the C escaper held in reserve.
The benchmark (`docs/rfcs/refs/rfc-0039-escaper-bench-20260910.md`) decided it: a foreign call per
special costs 2 to 3 microseconds under mhs, which only tied the `String` round-trip on the densest real
document and was three times slower on a special-dense fixture, while the C escaper is 68 times faster on
prose and 12 times faster on the dense fixture.

### One streaming file-reading utility

`MicroHttp.Stream.fileEnumerator` already streams a file into an iteratee in fixed-size chunks; this RFC makes it
the one way documents are read, with the chunk size a parameter (the current 4096-byte constant suits socket
traffic; document scanning wants 64K-128K). Every consumer below is an iteratee fed by it, so "true constant
space" means one chunk plus a bounded carry, never a whole document. The frontmatter reader is the same
utility with an early-completing iteratee: it returns as soon as it has seen the closing `---`, and the
enumerator stops feeding and closes the file. Nothing reads a whole document into the Haskell heap.

### A shared, pure scanner core

Byte scanning is one implementation, `scanStep :: ScanState -> ByteString -> (ScanState, [Link])`, where the
state carries the fence flag and the carried tail. It is the memchr scan of today's `pageLinks`, so it stays
pure under ADR-0086 (a deterministic `memchr` over a private `useAsCStringLen` copy, wrapped in
`unsafePerformIO`). Today's `pageLinks :: ByteString -> [Link]` becomes `scanStep` applied to a single chunk,
and the streaming file scan is `scanStep` folded over chunks -- the same code path, so byte-identical results
are guaranteed by construction rather than by keeping two scanners in step. The small pure callers
(`DocumentListing` scanning one line, `LinkIndex.pageTargets`) keep calling the pure form.

Two properties make the chunking safe. A document smaller than the chunk is read as one chunk, which is
exactly today's whole-body scan, so the common case is unchanged; chunking engages only for large documents,
where constant space is the point. Across a boundary the scanner **carries the incomplete tail** (the bytes
after the last newline) into the next chunk. That tail is **capped**: both things the scanner must see
contiguously -- a `](target)` and a fence marker at line start -- are short, so a bounded tail (a few KB)
never splits one, and a pathological single line longer than the cap is treated as a hard break rather than
allowed to grow the carry back into a whole-body read. Resident memory is one chunk plus that bounded tail.

### Streaming the link-index build

The cold build and reload fold `scanStep` over each document's chunks, applying `updatePage` with the targets
and discarding the bytes, rather than materialising `[(PagePath, ByteString)]`. `updatePage` takes the
computed targets, so it stays pure; only the driver that reads files is `IO`. The accumulated index
(O(links)) is the only thing that grows.

### Streaming the rewrite on move

`rewriteLinks` today reads the whole body, computes `(start, end, replacement)` offsets from `pageLinks`,
splices, and overwrites the file in place with `BS.writeFile`. It becomes a **fused streaming
scan-and-rewrite**: per chunk plus carried tail, `scanStep` finds each link and the rewriter emits the chunk's
bytes with each target replaced per the move mapping, written to a temporary file, which is then
`renamePath`'d over the original. Offsets never leave the chunk, so the offset-splice API retires. Each
referrer (from the O(1) link-index lookup) and the moved page itself is streamed independently, so moving a
very large document is constant-space end to end -- and the temp-then-rename makes the write **atomic**,
fixing the current in-place overwrite that a crash mid-write would corrupt. The `SharedAsset` copy
(`BS.readFile >>= BS.writeFile`) on the same path is streamed the same way.

### Frontmatter title without unpacking

The frontmatter title comes from the streaming utility's early-completing reader, which consumes chunks only
until the closing `---` and decodes just that small block, so a title lookup never reads or unpacks the body.
`breadcrumbsFor`, `documentPageTitle`, the navigation labels, and the `TreeMove` title lookup route through
it; `readDocumentText`, which unpacked a whole file to a `String`, is gone. When the body is already in hand
(the editor page has just read it), the title is taken from the frontmatter slice of those bytes rather than
re-reading.

Everything about the block lives in one module, `Verso.Frontmatter`: the classification of bytes as no
frontmatter, an unclosed block, or a closed block; the iteratee that completes on the closing delimiter;
the file reader over it; and the `name` parser. An unclosed block is abandoned once it passes a 64KB cap,
so a document that never closes its frontmatter is not read whole either. This consolidated three parsers
that had drifted apart (the tolerant one behind page titles, a stricter one in `TreeMove`, and the
byte-level delimiter test in the search chunker) onto one rule: a delimiter is `---` alone on its line with
spaces, tabs, and a carriage return tolerated around it, and the `name` value may be single- or
double-quoted. The only observable differences are at those edges (a tab-indented or trailing-space
delimiter, a single-quoted name in a synthesised listing entry), where the readers now agree.

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
- **A pure Haskell escaper over `memchr`.** Unescaped runs as O(1) slices, entities as shared constants,
  the next special found by `memchr` and the pieces joined pairwise. Measured and rejected: mhs charges 2
  to 3 microseconds per foreign call, so one call per special only tied the `String` round-trip on the
  densest real document and lost three-fold on a special-dense fixture. The C escaper (adopted) makes two
  calls per document.
- **Escape into a `Builder` of per-special nodes.** Rejected: thousands of builder nodes are ~1ms each to
  force in mhs, so a special-heavy document would serialise in seconds. The one-chunk property is kept.
- **A pure C escaper under `unsafePerformIO`.** The C escaper writes an output buffer, which is outside
  the read-only shape ADR-0086 sanctions. Rather than widen the ADR, the escaper is `IO` and the view takes
  the opaque `Escaped` result; the handlers were already in `IO`.
- **Make the scanner `IO` and drop `unsafePerformIO`.** Rejected: the file-level driver is `IO` anyway, but
  the scanner has pure callers on small inputs, so this either makes them `IO` or forces a second pure
  scanner -- two implementations to keep byte-identical. ADR-0086 records the sanctioned pure-FFI idiom that
  lets one core serve both.
- **Keep two resident chunks and scan across them.** Rejected in favour of a capped tail-carry: two separate
  ByteStrings cannot be `memchr`'d as one without concatenating, which is just a sliding window, and the
  tail-carry holds one chunk plus a bounded tail rather than two chunks.
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
- The streaming scanner produces the identical `[Link]` as `pageLinks` on every fixture, and on fixtures split
  at 4K, 64K, and 128K chunks with boundaries forced to land mid-link and mid-fence-marker; a single-line
  fixture longer than the tail cap proves the carry stays bounded.
- A move rewrite over a large fixture is byte-identical to the whole-body `rewriteLinks`, and a simulated
  failure before the rename leaves the original file intact.
- Frontmatter-title tests (in `AppSpec`) still pass; add cases for a document whose body dwarfs its
  frontmatter to prove the body is not read.
- A guard that the server survives fetching the largest fixture document under a deliberately small heap,
  and that startup over a multi-document fixture does likewise.
- `make check` stays green throughout.

## Rollout Plan

Riskiest-value-first, each a small commit with `make check` green, the heap left generous until the end.

1. Record ADR-0086 (done alongside this revision) and retire the `consoleQuiet` global by injecting the
   console sink -- a small separate change, so the sanctioned `unsafePerformIO` set is exactly the scanners.
   **Done (2026-09-10).**
2. Byte-level escaper in `MicroHttp.Html`, with the golden test and the bench. **Done (2026-09-10)**, as
   a C escaper in `IO` (see the escaper benchmark ref).
3. The streaming utility: parameterise `fileEnumerator`'s chunk size and add the early-completing
   frontmatter reader; route the title lookups through it. **Done (2026-09-10).**
4. The shared `scanStep` core with capped tail-carry, expressed so `pageLinks` is its single-chunk case;
   golden equality across chunk sizes; `bench-link-parse` at 4K/64K/128K against the whole-body baseline
   and the cello-docs build time -- this is the profiling gate, and it decides whether a `cbits` scanner is
   needed. **Done (2026-09-10).** `bench-link-parse` on the 76KB page: whole-body 7.4ms, chunked at
   4K/64K/128K 7.1 to 7.2ms, cells equal (15.2MB per parse either way), so no `cbits` scanner. Equality
   holds at every split point of a fixture and byte-by-byte; the tail cap is 64KB, and a line past it is
   scanned as a hard break with the carry emptied. The build time is measured in step 5.
5. Stream the link-index cold build and reload over the core. **Done (2026-09-10).** Every page the
   store reads (cold build, refresh, incremental patch, subtree restore) is scanned as a 64KB stream and
   folded into the index before the next is opened. On cello-docs (3980 documents) with the 16M-cell heap
   the cold build took 7.7s against 9.0s before, at 269MB RSS against 290MB; with a 4M-cell heap it now
   survives startup (18.3s, GC-bound, 73MB RSS), where the materialised build needed 8M.
6. The fused streaming rewrite on move, with temp-then-rename; stream the asset copy. **Done
   (2026-09-10).** `Verso.LinkRewrite` scans each chunk with the shared core, puts the links it settles to a
   per-link decision (`DocumentLinks.moveLinkEdit` / `pageMoveLinkEdit`, which the pure planners are now
   built from), splices the settled bytes and writes them to `<page>.tmp`, renamed over the page at the
   end; a page nothing changed in is left untouched. Candidate pages reach the planners as `(path, links)`
   rather than bodies, so the index-backed move holds no body at all (the no-index fallback still reads
   each body for its byte prefilter, then keeps only the links). The shared-asset copy streams through
   `Stream.copyFile`. Left as is: the asset-conflict check still reads both files whole to compare them.
7. The minor reads (`Log` size via `stat`, `OperationLog` streaming parse). **Done (2026-09-10).** The
   rotating appender seeds its size from `stat`; the operation log is streamed and parsed a line at a time,
   with the partial last line carried between chunks.
8. Lower the `VERSO_HEAP_CELLS` default to the tight fail-fast value, after exercising the largest documents
   and realistic concurrency on the real corpus. **Done (2026-09-10).** 8,000,000 cells (122MB), from
   16,000,000: the real corpus builds its index and serves twelve concurrent large-document edits at 4M, so
   8M is twice the measured floor; the cold build costs 9.7s against 7.7s. Search on is unaffected. The
   measurements are in `docs/rfcs/refs/rfc-0039-heap-sizing-20260910.md`.

## Open Questions

- ~~The exact tight default.~~ 8,000,000 cells, twice the measured floor of 4,000,000 (see the heap sizing
  ref).
- ~~Whether a `cbits` escaper is needed.~~ Decided by the step-2 benchmark: it is (see the escaper
  benchmark ref).
- ~~The tail cap size.~~ 64KB (`DocumentLinks.tailCapBytes`): far beyond any `](target)` plus fence
  marker, and still a bounded carry beside a 64KB chunk. A single line longer than that (a data URI, say)
  is scanned as a hard break, and only a link or fence marker split by that break is affected.
