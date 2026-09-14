---
id: RFC-0043
name: Streaming I/O by default
status: Implemented
owners:
    - alistair
created: 2026-09-14
updated: 2026-09-14
supersedes: []
superseded_by: null
---

# RFC-0043: Streaming I/O by default

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-14 |
| Started   | 2026-09-14 |
| Completed | 2026-09-14 |

## Summary

Make streaming the default way production code reads a file or a subprocess's output, and make that
default cheap to reach for: a short guide of recipes over the existing `MicroHttp.Stream` folds, a
`Process.withCapture` bracket so a subprocess's output is consumed as lines the way a file is, a lint gate
that fails any new whole-file read in `src/` that does not carry a stated bound, and a memory benchmark that
measures the process's resident high-water mark, which the fixed MicroHs heap cannot bound because
`ByteString` payloads live outside it. The two remaining unbounded whole-file reads (the persisted link index
on load, and `git log` output for a page's history) move onto the streaming folds, and the unused
`Draft.readDraft` is deleted.

## Context

ADR-0091 made block streaming the default for unbounded inputs, and RFC-0039, RFC-0040 and RFC-0042 moved
the document, request, response and form paths onto it. A survey of what is left (2026-09-14, the RFC-0041
review session) found every remaining whole-file read either bounded by a small fixed input, or recorded
with a reason, except two that grow with the corpus or its history:

- `LinkIndexStore.loadValidState` reads the whole persisted index with `BS.readFile` (1.2MB at 3,980
  documents) before splitting it into rows, although `persistState` already writes it one line at a time.
- `Git.logForPath` reads all of `git log --follow` into memory through `Process.runProcess`, whose capture
  is unbounded by construction. The diff and show-at-revision paths already have captured, streamed
  variants; the history path does not.

Two facts about the MicroHs runtime shape the rest of this RFC. First, a `ByteString` is one arena cell (a
`T_FORPTR` node) whose bytes are `malloc`'d outside the arena and freed by a finalizer the collector runs
in its sweep. So a whole-file read costs almost no heap cells and cannot exhaust the heap; it costs
resident memory, and that memory is only reclaimed when a collection happens, which is triggered by cell
exhaustion, not by bytes. A burst of large reads with little cell allocation between them inflates RSS well
past the 122MB arena with nothing to stop it. Second, a slice (`BS.take`, `BS.drop`) shares its parent's
finalizer, so holding a small view keeps the whole buffer alive. Together these mean the heap setting
(`VERSO_HEAP_CELLS`, 8,000,000 cells) bounds the Haskell live set but says nothing about the process's
high-water mark, and the RFC-0039 heap sizing runs measured RSS growing with heap size for exactly this
reason. Nothing measures that high-water mark today.

Converting a whole-file read is also more work than writing one. `BS.readFile` is one call; the streaming
equivalent requires knowing that `Stream.foldFileLines` exists, what its error type is, and that a
subprocess's output has to be captured to a file first. A default that is harder to reach than the thing
it replaces will not hold.

## Phase Item Completion Instructions

When a checklist item is completed, tick it and, if the work deviated from the item as written, add a
dated Done note stating what was done instead and why.

## Goals

- A guide, `docs/guides/streaming-io.md`, that gives the streaming recipe for each shape of read a handler
  meets (lines, blocks, a containment test, a comparison, a copy, a subprocess's output, a served body),
  each as a few lines of code that can be pasted.
- `Process.withCapture`: run a subprocess and hand its capture to a consumer, removing the capture files
  afterwards however the consumer exits, so the streaming form of "run git and read its output" is a
  bracket around `Stream.foldFileLines`, not a manual `removeCapture`.
- The link-index load and `git log` history parse fold lines from their sources; neither holds the whole
  input.
- A lint gate: every `readFile`, `readFileStrict` or `hGetContents` in production `src/` carries a
  `-- whole-file:` annotation naming its bound on the same line, or the build fails. The survey's bounded
  sites are annotated; new ones must be.
- A memory benchmark, `make bench-memory`, that runs a fixed scenario set against `build/verso` at a chosen
  heap size and reports the peak resident set per scenario, with the first results recorded under
  `docs/rfcs/refs/`.
- `Draft.readDraft` deleted (no production caller since RFC-0040 streamed the edit view).

## Non-Goals

- Changing the MicroHs runtime, its collector, or when it collects.
- Streaming the search indexer's page read was a non-goal as authored (the page was read whole, then
  chunked at heading boundaries, then embedded chunk by chunk; the C-side embedder's transient is two
  orders larger). It was then asked for and done the same day; see "Addendum: the streamed chunker".
- A memory cap or watchdog in the server.
- Rewriting the bounded reads (config file, model vocabulary, sidecars, manifests, `index.md`).

## Proposal

### The recipes

`MicroHttp.Stream` already has the folds; the guide names them by the shape of the read:

| Shape                            | Recipe                                                                                                        |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Parse a line-oriented file       | `Stream.foldFileLines step initial path`                                                                      |
| Scan a file in blocks            | `Stream.foldFileBlocks blockBytes step initial path`                                                          |
| Does a file contain these bytes  | `Stream.fileContains needle path`                                                                             |
| Are two files identical          | `Stream.filesEqual a b`                                                                                       |
| Copy a file                      | `Stream.copyFile from to`                                                                                     |
| Write lines                      | `Stream.writeFileLines path lines`                                                                            |
| Parse a subprocess's output      | `Process.withCapture exe args cwd stdin (\cap -> Stream.foldFileLines step initial (Process.captureOut cap))` |
| Serve a file, transformed or not | `Http.FileBody`, `Stream.transformedFileBody`                                                                 |

The only new function is `Process.withCapture`:

```haskell
withCapture :: FilePath -> [String] -> Maybe FilePath -> Maybe BS.ByteString -> (ProcCapture -> IO a) -> IO a
```

It is `runProcessCaptured` followed by the consumer, with `removeCapture` run on every exit, including an
exception. `runProcess` stays for commands whose output is a status line (`rev-parse`, `diff --cached
--quiet`), and its Haddock says so.

### The two conversions

`LinkIndexStore.loadValidState` folds `parseRow` over the index file's lines into an accumulator of edge
rows and fingerprint rows, with a corrupt-line flag; a set flag is the existing "corrupt, rebuild" path. The
row format and the reuse-or-rebuild decision are unchanged; `parseRows` over a whole `ByteString` goes.

`Git.logForPath` runs `git log` under `withCapture` and folds `parseRevision` over the stdout lines,
newest first as before. `Git.diffBetween` and `Git.showFileAtRevision`, the whole-value variants that only
tests still call, are deleted; the tests use the captured variants and read the small capture files
themselves.

### The gate

`make lint` gains a grep over `$(SRC)` and `$(MICROHTTP_SRC)` for `readFile`, `readFileStrict` and
`hGetContents`. A matching line passes only if it also contains `whole-file:`. The annotation is a comment
on the same line stating the bound, for example `-- whole-file: the YAML sidecar, a few hundred bytes`.
Haddock lines that merely mention the names are excluded by requiring a call shape (the name followed by a
space and an argument, not by a backtick or `@`). The survey's bounded sites are annotated in this RFC.

### The memory benchmark

`test/bench/memory-bench.sh`, run by `make bench-memory`, builds `build/verso` through the Makefile, starts
it on a private port from a generated config against a corpus given by `MICROHTTP_BENCH_TREE` (defaulting
to the search-demo corpus), samples its resident set every 100ms for the life of the run, and drives one
scenario at a time, printing the peak RSS observed during each:

1. Cold start with the persisted link index deleted (the link-index build).
2. Twelve sequential reads of the largest document's edit view.
3. Four concurrent reads of the same view.
4. One raw `PUT` of a document body of `MICROHTTP_BENCH_UPLOAD_BYTES` (default 8MiB) as an asset upload.
5. One no-JS form save of the largest document.
6. A move of the directory holding the largest document and back.

Each scenario runs after a settle period and reports peak minus the pre-scenario baseline as well as the
absolute peak. The heap size is `VERSO_HEAP_CELLS` as for `run-verso`. One scenario at a time and one
upload at a time, with a hard abort if RSS passes `MICROHTTP_BENCH_ABORT_MB` (default 1500), following the
workstation's earlier lesson with concurrent uploads. Results go in
`docs/rfcs/refs/rfc-0043-memory-high-water-<date>.md`.

## Alternatives Considered

- A growable heap or a byte-pressure collection trigger: upstream MicroHs work, out of scope (RFC-0039).
- Forbidding `readFile` outright: the bounded reads are legitimate and small; an annotation records the
  bound where the reader will see it, and the gate makes an unannotated one a build failure.
- A `Stream.foldProcessLines` that hides the capture: rejected in favour of `withCapture` plus the file
  fold, so there is one line fold, and a caller that wants blocks or a rename uses the same bracket.
- A `MonadFail`-style early exit in `foldFileLines` for the corrupt-index case: not needed; a corrupt index
  is rare and finishing the fold costs one pass over a file that is then rebuilt anyway.

## Security Impact

None. Capture files stay under the temporary directory with unique names, as today; `withCapture` only
guarantees their removal.

## Reliability Impact

Positive. Two unbounded reads become bounded by a line; capture files can no longer be leaked by a caller
that forgets `removeCapture`; and the resident high-water mark becomes something a change can be measured
against instead of discovered in production.

## Compatibility Impact

`Git.diffBetween` and `Git.showFileAtRevision` are removed (test-only callers). `Draft.readDraft` is
removed. The persisted index format is unchanged. No configuration key changes.

## Testing and Quality Gates

TDD for the behaviour changes: each phase lists its tests before its implementation. `make check` under
both compilers, plus the new lint gate itself, which must fail on an unannotated read (verified once by
hand during phase 2 and recorded).

## Rollout Plan

### Phase 1: the memory benchmark

No behaviour under test; the script is measurement code (exempt from format and lint like the other
benches). Checklist:

- [x] `test/bench/memory-bench.sh` and `make bench-memory` as described, reusing the Makefile's
      `build/verso` and the `VERSO_HEAP_CELLS` variable. Done 2026-09-14 with additions found necessary
      while running it: the server runs under `/usr/bin/time -l` so the kernel's maximum resident set is
      reported alongside the sampled peaks (the sampled `ps` RSS dips when macOS compresses idle pages, so
      the "above baseline" column planned here was replaced by the raw baseline for context); the script
      refuses to start when its port is already bound and fails fast if the server exits during startup
      (a stray server from an earlier run had silently answered for a dead one); requests report a
      non-2xx status rather than aborting the run; the asset upload is the raw-body scenario, since a
      document `PUT` is capped at `formBodyLimit` (1 MiB) and the asset path at 10 MiB.
- [x] First run against the search-demo corpus and, if available, the real corpus profile
      (`build/cello-profile.conf`), at 8M and 4M cells, recorded in
      `docs/rfcs/refs/rfc-0043-memory-high-water-2026-09-14.md`. Done 2026-09-14: the high-water mark is
      the arena plus about 30MB in every configuration (155MB and 160MB at 8M cells, 91MB and 90MB at 4M);
      the cold link-index build is the peak; no streamed path adds a visible amount.

### Phase 2: `withCapture`, the conversions, the deletions

Tests:

1. Given a command that writes lines to stdout, when run under `withCapture` with a consumer that folds
   them, then the folded lines are the output and both capture files are gone afterwards
   (`ProcessSpec`).
2. Given a consumer that throws, when run under `withCapture`, then the capture files are gone and the
   exception propagates (`ProcessSpec`).
3. Given a page with three commits, when its history is read, then three revisions come back newest first
   with the fields parsed (`GitSpec`, existing coverage extended to assert the fields).
4. Given a persisted index, when it is reloaded, then it is reused, and rebuilt when stale (existing
   `LinkIndexStoreSpec` case, unchanged, proves the conversion is behaviour-preserving).
5. Given a persisted index with a malformed line, when it is loaded, then it is treated as corrupt and
   rebuilt (`LinkIndexStoreSpec`, new).

Checklist:

- [x] `Process.withCapture`, with Haddock on `runProcess` pointing at it for large outputs.
- [x] `Git.logForPath` folds lines under `withCapture`; `diffBetween` and `showFileAtRevision` deleted, the
      two integration specs moved to the captured variants.
- [x] `LinkIndexStore.loadValidState` folds lines; `parseRows` deleted.
- [x] `Draft.readDraft` and its two unit cases deleted; the remaining cases still cover write, has and
      delete.

### Phase 3: the gate and the guide

- [x] The remaining whole-file reads annotated with `-- whole-file:` and their bound (config file, model
      vocabulary, search marker, search page read, sidecars, manifests, `index.md`, `runProcess` capture).
- [x] The lint gate in `make lint`, and one deliberate unannotated read tried against it and reverted.
      Done 2026-09-14: a scratch `Verso.Bogus` module with a bare `BS.readFile` failed `make lint` with the
      gate's message and was removed; the gate also had to exclude a definition at column 0 (the
      `readFileStrict` signature and equation matched the call shape).
- [x] `docs/guides/streaming-io.md` with the recipe table and one worked conversion (the link-index load,
      before and after); ADR-0091 gains a line pointing at the guide and the gate; `docs/README.md` and the
      module index updated if a row changes. Done 2026-09-14: no module-index row changed;
      `docs/reference/benchmarks.md` gained the memory bench entry.

### Rollout Plan Escape Hatch

Each phase is independently revertible. If the gate proves noisy it can be narrowed to `BS.readFile` alone
without losing the two conversions.

## Findings from implementation (2026-09-14)

- The two conversions were behaviour-preserving under the existing specs: the corrupt-index case added
  for `LinkIndexStoreSpec` passed before the conversion (the whole-value parser already treated a
  malformed line as corrupt) and after it, which is the point of writing it first.
- The lint gate needed one refinement beyond the design: a definition at column 0 (`readFileStrict`'s
  own signature and equation) matches the call shape and is excluded by position.
- `hlint` asked for `fromRight` on the fold's `Either`; a `case` with an explicit fall-through reads
  better and avoids an import, and is what landed.
- The memory bench took four attempts to measure the right thing; the Done note on phase 1 lists what
  each attempt taught. The lesson worth keeping is in the script header: check the port before starting,
  and cross-check sampled RSS against the kernel's maximum.

### Addendum: the streamed chunker (2026-09-14)

`Verso.SearchChunks` is now a line-fed state machine (`feedLine`, `finish`) driven two ways: `chunkPage`
feeds the lines of a page held whole (kept for the bench and the pure specs) and `chunkFile` folds a file
through it with `Stream.foldFileLines`, so what is live is one read block, the open paragraph and the open
piece, whatever the page's size. `SearchIndex.indexPage` reads the title through `Frontmatter.readBlock`,
chunks through `chunkFile` and fingerprints through `Fingerprint.contentFingerprintFile`; its `BS.readFile`
and annotation are gone. Four new `SearchChunksSpec` cases pin the streamed form to the whole-page form on
a page with frontmatter, nested headings and a fence; on a 170KB page whose headings and paragraphs
straddle the 64KiB read blocks; on an unclosed frontmatter block (content, as before); and on a missing
file (a failure, not an empty page). The one behavioural difference from the whole-page form is
deliberate and recorded in the code: an unclosed frontmatter block is held back as content only up to
64KiB before being replayed, where the whole-page form had no bound.

The first streamed version was 2.4x slower on MicroHs (`make bench-search-chunk`, cells per run for the
74KB bench page: 961K before, 2.35M after). The cause was `Data.ByteString.intercalate`, which under
MicroHs is `pack . List.intercalate . map unpack`: joining a paragraph's lines unpacked every byte of
the page to a list. `MicroHttp.Bytes` gained `concatBalanced` (pairwise appends, the shape RFC-0040
named) and `intercalate` over it; with those the chunker is at 1.26M cells and 9.3ms against 9.6ms
before, at time parity with a third more cells, which is the cost of assembling paragraphs from lines
rather than pointing at ranges of a whole page. Strict fields on the machine's record were tried and
made it slower under MicroHs (3.3M cells), so the record is lazy and the fold is `foldl'`.

## Open Questions

- Whether the memory benchmark should also sample the C-side allocations separately (the embedder and
  lancedb dominate RSS when search is on). The first run keeps search off and records that choice.
- What makes the sampled RSS dip to 17 to 40MB for a second or two mid-run on macOS while the arena stays
  allocated. The kernel maximum is unaffected, so it was not pursued.

## References

- ADR-0091: I/O is block streaming by default.
- RFC-0039, RFC-0040, RFC-0041, RFC-0042: the constant-space series this closes out.
- `docs/rfcs/refs/rfc-0039-heap-sizing-20260910.md`: the heap sizing runs and the RSS-grows-with-heap
  observation.
- `docs/reviews/rfc-0041-code-review-2026-09-14.md`: the survey of remaining whole-file reads.
- MicroHs `runtime/eval.c`: `T_FORPTR`, `mkForPtrFree`, and the finalizer sweep in `gc`.
