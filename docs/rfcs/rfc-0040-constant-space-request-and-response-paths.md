---
id: RFC-0040
name: Constant-space request and response paths
status: Draft
owners:
    - Alistair Bayley
created: 2026-09-11
updated: 2026-09-11
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0013, RFC-0014, RFC-0029, RFC-0032, RFC-0034, RFC-0039]
related_refs:
    - docs/rfcs/refs/rfc-0040-baseline-20260911.md
---

# RFC-0040: Constant-space request and response paths

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-09-11 09:32 NZST |
| Started   | 2026-09-11 11:57 NZST |
| Completed |                       |

## Summary

RFC-0039 made document *reading* and *indexing* constant-space and then tightened the MicroHs heap so a
regression fails loudly. It did not touch the request and response paths. A survey of the Haskell sources
found that every request body is still materialised whole, every HTML response is still concatenated whole,
the document save path still round-trips a megabyte of Markdown through `String`, and asset upload holds two
copies of a ten-megabyte body while it de-duplicates by whole-file comparison. This RFC inventories those
paths, owns the framework interface changes needed to fix them (a streaming body sink, a streaming HTML
response, byte-level form decoding, a streamed file comparison, and subprocess capture that stays on disk),
and sequences the work so each phase is measured before it is changed.

## Context

The heap is now a fixed 8,000,000-cell arena (~122MB, `VERSO_HEAP_CELLS`), chosen as twice the measured
floor for index building and twelve concurrent large-document edits. That choice assumed the paths RFC-0039
fixed were the only ones proportional to document size. They are not.

The survey (2026-09-11, over `packages/*/src`) found four cost classes, in descending order of what a
single request can pull into the arena:

- A whole request or response body held as one `ByteString`, plus the intermediates its assembly needs.
- A `ByteString` unpacked to `String`. Under MicroHs a cons cell per byte is roughly 24 bytes, so this is
  a ~24x multiplier on top of the whole-body cost, and the surviving instances are on the hottest write
  path in the application.
- `BS.concat` over many pieces, which in MicroHs is `foldr append` and so O(total x pieces).
- A whole result list retained while a later pass consumes it (chunk texts, token lists, embeddings).

Two constraints shape the fixes. First, the framework's stream contract (RFC-0012) already has both halves
of what is needed: `Iteratee.byteSinkI` and `resourceEnumerator` for ingest, `Http.StreamBody` and
`FileBody` for egress. The response side is materialised by choice, not by absence of an interface.
Second, ADR-0087 requires byte scanners to be `IO`, and production code under `packages/*/src` may not
import `System.IO.Unsafe`, so any new scanner or comparator is an `IO` action.

Phase 1 has since measured the three request paths on the real corpus at the current heap
(`docs/rfcs/refs/rfc-0040-baseline-20260911.md`), and it corrected the survey twice. The save path is not a
memory multiplier but a functional limit: a 32KB form body saves in 0.02s, a 64KB body takes 30s, a 128KB
body 161s, and a body near the 1 MiB cap does not finish at all. A heap-control run pinned the cause: the
same saves take 0.044s and 0.085s in a four-times-larger arena, so the code is linear and the time was
collection, but the cliff merely moves with the arena (128KB to 256KB at 32M cells) because the live set is
proportional to the body. Only removing the `String` round-trip fixes it. That path is `treeSave`, the
no-JavaScript form fallback, and not the editor's own save: the editor `PUT`s raw bytes to
`draftPut`/`treePutDocument`, which handle a body at the full 1 MiB cap in 9ms. The defect is confined to the
fallback, so phase 2 serves this RFC's no-document-sized-`String` goal rather than an outage. The upload
path costs about 56x the body in transient RSS, not the two copies the survey assumed, and because that
memory is `malloc`'d ByteString payload outside the cell arena it never reports `heap exhausted`. The
document render, ranked highest by the survey, turns out to be the cheapest of the three at corpus sizes.
Later phases still start by measuring the path they are about to change, in the manner of the RFC-0039 refs.

## Goals

- A request body is never materialised in the heap when its destination is a file. An upload of any size up
  to its cap costs a bounded buffer, not the body.
- A response body is never concatenated whole. A page embedding a document streams to the socket.
- No document-sized value crosses a `ByteString`/`String` boundary on any request path.
- Whole-file comparison, wherever it is used for de-duplication or conflict detection, is a streamed
  comparison preceded by a size check.
- Subprocess output that is destined for a response or a file is not read into the heap first.
- Byte-for-byte identical behaviour throughout: the same stored bytes, the same de-duplication decisions,
  the same HTML, the same commits, the same search results.
- Every site in the inventory below is either fixed or has a recorded reason for being left alone.

## Non-Goals

- Lowering `VERSO_HEAP_CELLS` again. The tight default is already in place; this RFC buys headroom under
  concurrency rather than a smaller arena. A re-tightening, if the measurements support one, is a follow-on.
- Raising the body caps. `treeAssetMaxBytes` and `formBodyLimit` stay where they are; making the paths
  constant-space is what would later *allow* raising them, which is a separate decision.
- Changing the link index's in-memory design. An index proportional to the corpus is RFC-0029's accepted
  choice; only the `String` spike when persisting it is in scope here.
- Streaming the search embedder or the ONNX runtime. Only the chunking and tokenising retention on the
  Verso side is in scope.
- RFC-0007 portability work. The new interfaces must not add platform-specific code beyond what
  `packages/micro-http/cbits` already carries.

## Proposal

### Constant-space path inventory

Every site the survey found, with the class of cost and the phase that addresses it. This table is the
tracker: a site is not closed until its phase is done or its row says why it stays.

| Site | Cost class | Bound | Phase |
| --- | --- | --- | --- |
| `Iteratee.readBodyStrict` ([Iteratee.hs:147](../../packages/micro-http/src/MicroHttp/Iteratee.hs)) | whole body, `BS.concat` over k pieces | per request cap | 2, 3 |
| `treeSave` body ([App.hs:1615](../../packages/verso/src/Verso/App.hs)) | whole body, then `String` round-trip | measured: unusable past ~64KB (no-JS fallback only) | 2 |
| `treePublish`, `treeDiscard`, history posts (App.hs:1576, 1652, 1676) | whole body, then `String` | 1 MiB per request | 2 |
| `treeUpload` body ([App.hs:1085](../../packages/verso/src/Verso/App.hs)) | whole body, `BS.concat` over ~2,560 chunks | fixed: `Stream.fileSinkI`, +11MB per 10 MiB body | 3 |
| `storeAsset` write and dedup compare ([App.hs:1132](../../packages/verso/src/Verso/App.hs)) | whole write, plus whole read to compare | fixed: rename plus `Stream.filesEqual` | 3 |
| `TreeMove.assetConflicts` ([TreeMove.hs:361](../../packages/verso/src/Verso/TreeMove.hs)) | two whole files compared | fixed: `Stream.filesEqual` | 3 |
| `htmlResponseChunks` ([App.hs:1926](../../packages/verso/src/Verso/App.hs)) | `BS.concat` of the whole page | per response | 4 |
| `treeEdit`, `treeRead`, `treeReadAt` (App.hs:1007, 1029, 1737) | whole document, escaped whole, in a whole page | measured: ~6MB at 263KB | 4 |
| `treeDiff` via `Git.diffBetween` ([Git.hs:163](../../packages/verso/src/Verso/Git.hs)) | whole diff, then `String` | unbounded | 5 |
| `Process.runProcess` capture ([Process.hs:121](../../packages/micro-http/src/MicroHttp/Process.hs)) | whole stdout and stderr | unbounded | 5 |
| `Git.showFileAtRevision` and rollback write (Git.hs:169, App.hs:1766) | whole file | document size | 5 |
| `TreeMove` `collect` ([TreeMove.hs:751](../../packages/verso/src/Verso/TreeMove.hs)) | whole file per document, whole corpus walked | one document at a time | 6 |
| `TreeMove.readRel` and `writeRel` (TreeMove.hs:786, 795) | whole file, then `String` | index.md size | 6 |
| Trash manifests and asset sidecar reads (TreeMove.hs:334, 505, 608) | whole file, then `String` | manifest size | 6 |
| `DocumentMeta.readMetaFile` ([DocumentMeta.hs:188](../../packages/verso/src/Verso/DocumentMeta.hs)) | whole file, then `String`, rewritten per upload | sidecar size | 6 |
| `Draft.readDraft` and `writeDraft` (Draft.hs:36, 44) | whole document | document size | 4 |
| `SearchIndex.indexPage` ([SearchIndex.hs:267](../../packages/verso/src/Verso/SearchIndex.hs)) | whole page, plus chunk texts, tokens, embeddings retained | multiple of page | 7 |
| `SearchChunks.chunkPage` line ranges and chunk copies (SearchChunks.hs:53, 82) | list per line, `BS.concat` per chunk | multiple of page | 7 |
| `SearchIndex.reconcile` fingerprint read ([SearchIndex.hs:373](../../packages/verso/src/Verso/SearchIndex.hs)) | whole page to hash | document size | 7 |
| `Concordance.Store.withPackedBytes` and `packStrings` (Store.hs:246, 253) | `BS.concat` of all chunk texts, one via `String` | page's chunks | 7 |
| `LinkIndexStore.serialiseState` ([LinkIndexStore.hs:215](../../packages/verso/src/Verso/LinkIndexStore.hs)) | whole index as `String` before packing | ~24x index | 8 |
| `Html.escapeChars` ([Html.hs:453](../../packages/micro-http/src/MicroHttp/Html.hs)) | `String` escape path | input size | 8 |
| `LinkIndexStore.parseRows` ([LinkIndexStore.hs:234](../../packages/verso/src/Verso/LinkIndexStore.hs)) | `BS.split` over the 1.2MB persisted index (unpack scan; collector-stack hazard) | fixed: `Bytes.split` | 2 audit |
| `TreeMove` `collect` `isInfixOf` ([TreeMove.hs:752](../../packages/verso/src/Verso/TreeMove.hs)) | `BS.isInfixOf` unpacks each whole page | fixed: `Bytes.isInfixOf` | 2 audit |
| `Concordance.Fingerprint` ([Fingerprint.hs:18](../../packages/verso/src/Concordance/Fingerprint.hs)) | `BS.foldl'` unpacks each whole page | fixed: `Bytes.foldl'` | 2 audit |
| `Concordance.WordPiece.mkVocab` ([WordPiece.hs:68](../../packages/verso/src/Concordance/WordPiece.hs)) | `BS.split` over the 231KB vocab | fixed: `Bytes.split` | 2 audit |

Sites the survey cleared, recorded so a later reader does not re-open them: static asset serving already
uses `FileBody` (App.hs:1060); `Log.rotatingAppender` stats rather than reads (Log.hs:197); the header
builders' `BS.concat`s are over small fixed lists (Http.hs:433-487); `LinkIndexStore.loadValidState` reads a
file whose size is the index's own, which RFC-0029 accepts.

The phase-2 audit of unpack-based `ByteString` scans (every non-primitive `Data.ByteString` function under
MicroHs is `Data.List.f . unpack`; see `MicroHttp.Bytes`) found sixteen call sites. Four had document- or
corpus-sized inputs and are in the table above. The rest are bounded and stay on the library functions:
`Middleware.parseRequestLine`'s `words` and the head `breakSubstring` see at most `maxHeaderBytes` (8KB);
`OperationLog.operationsI`'s `split` sees one 64KB stream chunk plus a line carry; `DocumentLinks`'
`takeWhile` sees one link target within a line under the 64KB tail cap; `Git.parseLog`'s `lines` sees one
`git log` output, 4KB today on the real corpus and growing only with a page's history; `Git.parseRevision`'s
`split` sees one log line.

### Streaming request bodies to a file

The framework gains one interface: a body sink that writes what it receives to a file handle and returns
the byte count, built from the existing `Iteratee.byteSinkI` the way `Stream.copyFile` is built from
`resourceEnumerator`. It enforces the caller's cap while streaming and fails with the caller's error at the
cap, so `readBodyStrict`'s limit semantics carry over unchanged.

`treeUpload` then becomes: create the assets directory, sink the body to `<assets>/<name>.tmp`, decide the
final name, rename into place. The body never exists as a value. `readBodyStrict` itself stays for the
small-cap handlers, but its `BS.concat` is replaced by `DocumentLinks.concatBalanced`'s pairwise shape,
lifted into the framework so the framework does not depend on an application module.

### Byte-level form decoding

`formFields` and `Http.decodeFormValue` move to `ByteString`, so a form body is split and percent-decoded
as bytes and the field the save path wants (`markdown`) is handed to `Draft.writeDraft` or
`writeDocumentBytes` as bytes. `normaliseNewlines` becomes a byte pass. No document-sized `String` is
constructed. The `String`-valued `formFields` stays only where the fields are genuinely small identifiers
(`rev`, `path`, `name`), as a wrapper over the byte version.

This is the phase with the largest expected win for the least structural change, and it is confined to
`Verso.App` plus one `MicroHttp.Http` function.

### Streaming HTML responses

`Html.renderChunks` already produces coalesced buffer-sized segments; `htmlResponseChunks` concatenates
them again. The fix is an `Html` response that carries the chunk list as a `StreamBody` through
`Iteratee.strictEnumerator`'s list analogue, so the segments reach the socket as they are produced.

The document views are the reason this matters: `treeEdit`, `treeRead` and `treeReadAt` read a whole
document, escape it whole, embed it in a whole page, and concatenate that. Making the response a stream
removes two of those copies. Removing the other two means the escaped document reaches the page as a
producer rather than a value, which is the one genuine interface question in this RFC: an `Html` fragment
whose content is an enumerator rather than bytes. The phase is scoped to answer it with a measurement
first, because a chunk-at-a-time `Escaped` changes the `Html` type's shape and that decision is
ADR-worthy (see below).

Content-Length is already computed per body variant in `Middleware` (Middleware.hs:149-162), so a streamed
page uses the counted-stream path that `StreamBody` responses already use.

### Streamed file comparison

One `FileSystem` helper: compare two paths for byte equality by stat-ing both for size, returning `False`
immediately on a mismatch, and otherwise streaming both through a fixed buffer. It replaces the whole-file
comparison in `storeAsset` and in `TreeMove.assetConflicts` (which RFC-0039 step 6 explicitly left as is).

### Subprocess capture without a heap copy

`Process.runProcess` writes the child's stdout and stderr to temp files and then reads both whole. The
capture files already exist on disk, so the fix is a second entry point that returns the capture paths and
leaves the reading to the caller, letting `Git.showFileAtRevision` rename the capture into place for
rollback and letting `treeDiff` serve the diff as a `FileBody`. The existing bytes-returning entry point
stays for the many small commands (`git log`, `git commit`, `git rev-parse`).

### Search-side retention

`SearchIndex.indexPage` holds a page, its chunk texts (each a fresh copy), every chunk's token list, and
every chunk's embedding, at once. The phase measures the real peak on the largest corpus document before
deciding how far to go; the cheap parts are streaming `contentFingerprint` in `reconcile` so a page is not
read to be hashed, and processing chunks in bounded batches rather than accumulating `mapM` results.
Reshaping `chunkPage` to yield ranges rather than materialised copies is the larger change and may be
deferred with a recorded reason.

### Anticipated ADRs

| Decision                                                                      | Why it is load-bearing beyond this RFC                                           |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| HTML responses are streamed, not materialised                                 | Changes the application response contract (RFC-0012, RFC-0013) for every handler |
| Request bodies destined for files never enter the heap                        | Sets the rule new upload-shaped handlers must follow                             |
| Form bodies are decoded as bytes; `String` fields are for identifiers only    | A boundary rule the whole application must respect, not one path's fix           |
| Subprocess capture stays on disk when its destination is a file or a response | Shapes every future external-command integration                                 |

Each is recorded only if the phase that reaches it confirms the decision; a phase whose measurement says
the change is not worth making records that instead, in this RFC.

## Alternatives Considered

- **Raise the heap again.** Restores headroom without fixing anything and gives up RFC-0039's fail-fast
  property, which is exactly the property that surfaced these paths. Rejected.
- **Keep `readBodyStrict` and only fix its `BS.concat`.** A balanced concat turns O(total x pieces) into
  O(total log pieces), which helps the 10 MiB upload materially but still holds the whole body, and still
  holds two copies during the dedup compare. Worth doing for the small-cap handlers, not sufficient for the
  upload path. Adopted as the fallback, not the fix.
- **Cap document size lower instead of streaming the save path.** `formBodyLimit` is already an undocumented
  1 MiB ceiling on a saved document. Lowering it makes the memory problem smaller by making the product
  worse; the `String` round-trip is the actual cost and it is removable. Rejected.
- **A C scanner for form decoding.** The escaper precedent (RFC-0039 step 2) shows a `cbits` pass can win
  where the per-byte work is trivial. Percent-decoding is trivial per byte, so this may be tempting. Not
  proposed: the byte-level Haskell version removes the ~24x multiplier, which is the whole win, and the
  project's standing preference is Haskell where the cost allows. Revisit only with a measurement.
- **Chunked transfer encoding for streamed pages.** Not needed: `Middleware` already counts a stream to
  produce Content-Length, and the pages are bounded by the document. Out of scope.

## Security Impact

The upload path stops holding attacker-controlled bodies in the heap, so a burst of concurrent
at-the-cap uploads costs bounded buffers plus disk. Today it costs ~560MB of transient allocation for a
single at-the-cap upload, and four concurrent uploads took the server above 25GB resident and exhausted the
host (phase 1 baseline). The per-request cost grows under concurrency rather than holding steady, because a
ByteString payload is `malloc`'d outside the cell arena and so does not count toward the pressure that
triggers a collection: the intermediates are garbage immediately but nothing prompts the collector to
reclaim them. Neither of RFC-0039's safety nets covers this -- not the tight arena, which this memory
bypasses, and not `heap exhausted`, which never fires. This is a denial-of-service lever available to any
client allowed to upload, and it is the strongest single argument for phase 3. That removes
a cheap memory-exhaustion lever against a fixed, non-growable heap: today enough simultaneous uploads can
reach `heap exhausted`, which is a fatal crash, not a rejected request.

Streaming to a temp file moves that pressure to disk, which needs its own bound: the temp file is written
under the target assets directory, is subject to the same cap while streaming, and is removed on every
failure path. The cap check must stay *ahead* of the write, so an over-cap upload cannot leave a
full-size temp file behind.

No change to path validation, to the allowed-extension check, or to who may upload; those decisions stay
where they are in `Verso.Attachment` and `Static.resolveStaticPath`.

## Reliability Impact

Removed: a fatal `heap exhausted` on concurrent large uploads or saves, which today takes the whole server
down rather than failing one request.

Introduced, and to be handled explicitly in each phase:

- A temp file left behind by a failed upload or a failed streamed rewrite. Every new sink follows the
  existing temp-then-rename discipline (`Verso.LinkRewrite`, `LinkIndexStore.persistState`) and removes its
  temp file on failure.
- A streamed response that fails mid-body has already sent a 200 status. This is not new: `FileBody` and
  `StreamBody` responses have the same property today, and the stream error vocabulary already distinguishes
  a write failure from a source failure.
- A streamed comparison that races a concurrent write to either file can report a stale answer. The
  whole-file comparison it replaces has the same race; the size pre-check narrows rather than widens it.

## Compatibility Impact

No stored data changes. No configuration key changes. `max_body_bytes`, `treeAssetMaxBytes` and
`formBodyLimit` keep their current values and meanings.

The framework interfaces change, which matters to `packages/verso` only, since `micro-http` has no other
consumer: `Http.decodeFormValue` becomes byte-valued, `Process.ProcResult` gains a
capture-path-returning sibling, `MicroHttp.FileSystem` gains a comparison helper, and
`MicroHttp.Iteratee`/`Stream` gain the body sink. `readBodyStrict` keeps its signature so the small-cap
handlers are untouched.

The one-way dependency rule from RFC-0030 holds: nothing application-shaped moves into the framework, and
the balanced concat is lifted as a general utility rather than as an import of `Verso.DocumentLinks`.

## Testing and Quality Gates

Behaviour to verify, one per operator-visible scenario:

- An asset upload at the cap stores bytes byte-identical to what was sent, and the response still names
  `assets/<name>`.
- An upload one byte over the cap is refused with the same status as today, and leaves no temp file.
- Re-uploading an identical file de-duplicates to the same name as today; re-uploading different content
  under a taken name suffixes to the same name as today.
- Saving a document with multibyte characters, percent-encoded separators, and CRLF newlines stores bytes
  identical to today's save, with versioning both on and off.
- A document page (edit, read, and read-at-revision) serves HTML byte-identical to today's, including for
  the largest corpus document.
- Rollback restores byte-identical content and commits it; a diff renders the same lines.
- A move that relocates assets still refuses the same conflicts, and still rewrites the same links.
- Search results and the indexing queue's behaviour are unchanged for a re-indexed page.

Gates that must stay green: `make check` in full, which covers the docs build, format, linters, the
Haskell unit and integration suites under both MicroHs and GHC, the editor checks, and the Playwright
smoke under both servers. Additionally, per phase:

- A memory measurement recorded as a ref under `docs/rfcs/refs/`, before and after, on the real corpus at
  the current 8,000,000-cell heap: peak RSS and whether the heap survives.
- A concurrency measurement for the upload and save phases: simultaneous at-the-cap requests, at the point
  where today's code is expected to exhaust the heap.
- The golden-output tests carry the byte-identity claims above; a phase that cannot show byte identity does
  not land.

## Rollout Plan

Each phase is a small commit with `make check` green, and each phase begins by measuring the path it is
about to change so the fix is justified and the win is recorded. The heap default is not touched.

### Phase 1: baseline measurement

- [x] Measure an at-the-cap upload, an at-the-cap save, and a largest-document page render on the real
      corpus at 8,000,000 cells: time, peak RSS, and whether the heap survives. **Done (2026-09-11.)** No
      path reports `heap exhausted`: the save path spends CPU at flat RSS, and the upload path inflates RSS
      outside the cell arena.
- [x] The heap-control experiment for the save cliff. **Done (2026-09-11.)** At `-H32000000` the 64KB save
      takes 0.044s against 30.08s (~685x) and the 128KB save 0.085s against 160.72s (~1,900x), and the
      scaling is linear (2x body, 1.93x time). So nothing is algorithmically quadratic; the 8M figures were
      measuring collection. But the cliff only *moves*: at 32M cells it sits between 128KB and 256KB, four
      times the arena for four times the body. Raising the heap is not the fix -- removing the `String` live
      set is, which is phase 2, and it should leave the 8,000,000-cell default comfortable.
- [x] ~~Take a GHC cost-centre profile of the save path.~~ **Skipped deliberately (2026-09-11.)** The
      heap-control run already established the shape (linear code, collection-bound at the default heap) and
      the cause (the `String` live set), so a cost-centre profile would only confirm it.
- [x] Establish which handler each client actually uses, before changing either. **Done (2026-09-11.)** The
      editor saves with a raw-body `PUT`; the measured form `POST` is the no-JavaScript fallback. Recorded
      in the baseline ref as a correction.
- [x] Record the numbers as a ref, and correct this RFC's inventory where the measurement disagrees with
      the survey's cost-model estimate. **Done (2026-09-11)**, three corrections, in the baseline ref.
- [ ] The concurrency measurement is **deferred to after phase 3, and must be bounded.** The first attempt
      (four simultaneous at-the-cap uploads) took the server above 25GB resident, exhausted the host's RAM
      and restarted its desktop session. That was a test-design error rather than a discovered limit, but
      the 25GB is itself a finding: the per-request cost rises under concurrency, which points at
      `malloc`'d ByteString payload being invisible to the collector's trigger. When taken, the measurement
      needs two requests rather than four, a 1 MiB body scaled arithmetically, a memory cap on the server
      process, and an abort threshold in the harness.

### Phase 2: byte-level form decoding on the save path

- [x] Byte-valued decoding: `Http.decodeFormValueBytes` and `Http.parseFormBody` in the framework;
      `formFields` reimplemented over them; byte `normaliseNewlineBytes`. **Done (2026-09-11.)**
- [x] `treeSave` takes the `markdown` field as bytes from socket to file. **Done (2026-09-11.)** The other
      form handlers carry only identifiers and keep the `String` wrapper over the byte parser.
- [x] Byte-identity tests: multibyte, `%20` and `+` spaces, CRLF and lone CR, versioning on (draft) and
      off (tree), plus the decoder's contract against the `String` decoder. **Done (2026-09-11.)**
- [x] Re-measure. **Done (2026-09-11.)** 64KB 30.08s to 0.16s; 256KB 0.23s; 512KB 0.42s; a body at the
      1 MiB cap 0.92s, all at the 8,000,000-cell default. The first cut overflowed the runtime stack past
      ~250KB; the cause was two mhs library scans (`elemIndex`, `notElem`) whose in-progress state the
      collector marks on the shared 250,000-slot stack, not the decoder. Recorded in the baseline ref.

### Phase 3: streaming upload and streamed comparison

- [x] The framework body sink, `Stream.fileSinkI`, with the cap checked ahead of every write and the partial
      file removed on the cap, on a transport failure and on a file that will not open. **Done (2026-09-11.)**
- [x] Streamed byte equality, `Stream.filesEqual`: a size check by `stat`, then 64KB blocks. It lives in
      `Stream` rather than `FileSystem` because it is handle I/O beside the file producers. **Done (2026-09-11.)**
- [x] `treeUpload` sinks to a temp file reserved in the assets folder (`FileSystem.reserveTempFile`, moved
      from `Process`) and `storeAsset` renames it into place, de-duplicating by `filesEqual`; the 404 and 415
      paths drain the body so nothing is left on the connection. **Done (2026-09-11.)**
- [x] `TreeMove.assetConflicts` compares by `filesEqual`; a file that cannot be compared counts as a conflict.
      **Done (2026-09-11)**, closing RFC-0039 step 6's leftover, with the refusal now covered by unit tests.
- [x] ~~Balanced concat for `readBodyStrict`.~~ **Not needed (2026-09-11.)** Phase 1 measured a body at the
      1 MiB cap through `readBodyStrict` at 9ms: it arrives in ~256 chunks, and the fold only bit at the
      upload's ~2,560, which the sink removes. Revisit if a strict-body caller's cap grows.
- [x] Re-measure the upload. **Done (2026-09-11.)** 10 MiB: 5.57s and +560MB resident before; 1.03s and
      +11MB after, bytes identical, no temp file left. ADR-0088 records the decision.
- [ ] The bounded concurrency measurement from phase 1: now safe in principle (expected ~11MB per request),
      still to be run with two requests, a memory cap on the server process and an abort threshold.

### Phase 4: streaming HTML responses

- [ ] Measure how much of the document-page cost is the page concat versus the escaped-document value, to
      decide whether the escaped document must reach the page as a producer.
- [ ] `htmlResponseChunks` becomes a `StreamBody` over the coalesced chunks.
- [ ] Depending on the measurement: an `Html` fragment whose content is a producer, or a recorded decision
      that the value-shaped `Escaped` stays.
- [ ] Byte-identity tests for the edit, read and read-at-revision pages, including the largest document.
- [ ] Record the response-contract ADR.

### Phase 5: subprocess capture and the git paths

- [ ] `Process` entry point returning capture paths, with the same cleanup guarantees.
- [ ] `Git.showFileAtRevision` and rollback stop routing a document through the heap.
- [ ] `treeDiff` serves the diff without a `String` copy.
- [ ] Record the subprocess-capture ADR.

### Phase 6: the remaining whole-file reads in the tree operations

- [ ] `TreeMove` `collect` moves onto `LinkIndexStore.scanPageLinks`, matching what `linksRel` beside it
      already does.
- [ ] `readRel`, `writeRel`, the trash manifests, the asset sidecar reads and `DocumentMeta` stop
      unpacking to `String`; each remaining whole-file read gets a recorded bound or a fix.

### Phase 7: search-side retention

- [ ] Measure `indexPage`'s peak on the largest corpus document.
- [ ] Stream `contentFingerprint` in `reconcile`; batch the chunk embedding rather than accumulating it.
- [ ] Decide, with the measurement, whether `chunkPage` is reshaped to yield ranges or left with a recorded
      reason.

### Phase 8: the remaining String spikes

- [ ] `LinkIndexStore.serialiseState` writes bytes without building the whole index as a `String`.
- [ ] `Html.escapeChars`: either retire the `String` escape path or record which callers may keep it and why.
- [ ] Close the inventory: every row is fixed or carries its reason.

## Open Questions

- Whether an `Html` fragment can carry a producer without making the `Html` type harder to use for the
  ordinary case. Phase 4's measurement decides whether the question needs answering at all.
- Whether `formBodyLimit` should be documented as a document-size ceiling in
  `docs/reference/configuration.md`, or replaced by a configuration key, once the save path no longer
  multiplies it. Out of scope to change here; in scope to decide where it is written down.
- Whether the temp file for a streamed upload belongs in the target assets directory (same filesystem, so
  the rename is atomic) or in the configured temp directory (tidier, but the rename may cross devices).
  Phase 3 settles it.
- Whether the phase-1 measurements justify all eight phases. A phase whose measurement shows no meaningful
  cost is closed with that finding recorded, not implemented.
