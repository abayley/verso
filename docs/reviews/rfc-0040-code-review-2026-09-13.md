# RFC-0040 code review: constant-space request and response paths

Status: review (2026-09-13). Change set `e26f4ba..03794ea` on `main` (RFC-0040 phases 1-9,
ADR-0089/0090/0091, RFC-0041). 83 files, about 3800 insertions and 550 deletions.

The review ran along two independent axes, each in its own sub-agent so neither could
colour the other: Spec (does the code do what RFC-0040 asked) and Standards (does the code
follow the documented conventions and avoid the Fowler smell baseline). The two reports are
kept separate below and are not reranked against each other. Each finding is labelled
MEASURED (a command was run), VERIFIED (the code or runtime source was traced end to end) or
INFERRED (a plausible reading not confirmed by execution).

Baseline for the review: the MicroHs unit suite at HEAD passes (471 examples, 0 failures,
MEASURED). The GHC suites and the full `make check` were not rerun; the handoff records them
green at HEAD.

## RFC-0040 Spec Findings

Ranked by severity. Byte-identity and resource-cleanup regressions are the top categories;
none of the byte-identity claims failed.

### Spec 1: `treeImageTitles` still widens a 1 MiB body to `String`

VERIFIED (code); the cost is MEASURED by the RFC's own phase-1 numbers.

The RFC's rule is "No document-sized value crosses a `ByteString`/`String` boundary on any
request path" (rfc-0040 line 77). Phase 2 records that "the other form handlers carry only
identifiers and keep the `String` wrapper" (line 399). `treeImageTitles`
([App.hs:1711](../../packages/verso/src/Verso/App.hs#L1711)) reads its body at
`formBodyLimit` (1 MiB) and then calls `formFields (BS.unpack bodyBytes)`. The bound is the
cap, not the identifiers: a client can post a 1 MiB body. The RFC measured that shape at 30s
for 64 KB and non-terminating near 1 MiB (lines 59-60) before phase 2 fixed `treeSave`.

Fix: parse with `Http.parseFormBody` on bytes and unpack only the small fields, or cap the
handler at a small limit of the `treeCreateMaxBytes` kind.

### Spec 2: the publish commit path unpacks the whole document under MicroHs

VERIFIED against the MicroHs runtime source.

[App.hs:1696](../../packages/verso/src/Verso/App.hs#L1696) comments "BS.unpack is lazy and
publishMessage reads only the frontmatter head, so the whole page body is never widened to a
String here" and passes `BS.unpack bytes` to `publishMessage`. Under GHC that is true. Under
MicroHs `Data.ByteString.unpack` is `primBSunpack`, and the runtime's `bsunpack`
(`MicroHs/src/runtime/eval.c`, around line 4636) builds the entire cons list in one C loop
after a `GCCHECK(strNodes(size))`. `Char8.unpack` is `map w2c . B.unpack`, so the `map` is
lazy but the byte list beneath it is fully materialised. Every publish therefore allocates
about two cells per byte of the saved document, up to the 1 MiB save cap, on the path phase 2
claims is byte-clean (line 398, "`treeSave` takes the `markdown` field as bytes from socket to
file").

This does not reintroduce the phase-1 cliff (that was the `String` decoder, not the list
itself), but it is a per-save spike of roughly the document size times 16 to 24 under the
production compiler, and the comment is wrong for the compiler the server ships on. Fix: give
`Frontmatter.title` a byte-valued sibling over `Frontmatter.readBlock`'s output, or take the
title from the leading block already read for the response.

### Spec 3: the draft edit view still materialises the whole page

VERIFIED.

"A response body is never concatenated whole" (line 76), and the inventory row
"`Draft.readDraft` and `writeDraft` | whole document | document size | 4" (line 122) has
neither a fix nor a recorded reason, which the RFC requires of every row (line 83). The
resume path ([App.hs:1004](../../packages/verso/src/Verso/App.hs#L1004)) reads the draft
whole and `editFromBytes` reaches `documentBytesResponse`
([App.hs:2079](../../packages/verso/src/Verso/App.hs#L2079)), which `BS.concat`s the shell,
the escaped document and the trailing chunks into one body. Its Haddock says phase 5 would
move it to the streamed shape, but phase 5 only touched the git captures. The draft is a file
on disk, so `documentFileResponse` applies directly; only the new-page seed still needs the
bytes form.

### Spec 4: ADR-0090 is stale after phase 9

VERIFIED.

[adr-0090](../adrs/adr-0090-subprocess-capture-stays-on-disk.md) says in Consequences and
"Reopens when" that `treeDiff` "stays on the byte-returning path". Phase 9 streamed it
(`Git.diffBetweenCaptured`, `diffStreamBody`). RFC-0040 line 479 still points readers at
that "Reopens when". The same ADR also says "Both read only the leading frontmatter block";
`treeRollback` reads none. The docs-only commits (1a7a38c, 79edee8, 03794ea) edited ADR-0091
only, so ADR-0090 was never brought up to date.

### Spec 5: RFC-0041 references a file that is not on `main`

VERIFIED. `spike/iteratee-multisource/Spike.hs` (rfc-0041 frontmatter `related_refs`, and
lines 34 and 280) exists only on the `spike/iteratee-multisource` branch. Line 258 says so in
prose, but the frontmatter reference will not resolve from `main`.

### Spec 6: capture and temp cleanup windows beyond the documented one

INFERRED from code reading; not reproduced.

ADR-0090 and ADR-0091 document one leak window: a streamed body that never runs because the
client is gone before the write. Two more exist.

- `treeReadAt` ([App.hs:1821](../../packages/verso/src/Verso/App.hs#L1821)): an exception in
  `loadPageAttachments`, `breadcrumbsFor` or `treeSpineFor` between the capture and the
  response leaks `captureOut`. The `handleClient` totality change (2315ae4) closes the socket
  on a crashing handler but removes nothing.
- `Stream.writeFileLines` ([Stream.hs:282](../../packages/micro-http/src/MicroHttp/Stream.hs#L282))
  leaks the handle if `hPut` throws, and `LinkIndexStore.persistState`
  ([LinkIndexStore.hs:208](../../packages/verso/src/Verso/LinkIndexStore.hs#L208)) leaves the
  `.tmp` in place on `Left`. The RFC says the persist "removes its temp file on failure"
  (lines 314-315).

`treeDiff` was traced on every branch (no-diff, failure, streamed completion, mid-stream
`Left`) and removes both captures.

### Spec 7: streamed diff holds one line as `String`

INFERRED. `View.diffScanStep` ([View.hs:412](../../packages/verso/src/Verso/View.hs#L412))
does `BS.unpack` per line. The RFC bounds this by "one change block" (line 546). A document
with no newlines makes one line document-sized, the same class as Spec 1 and 2, though this
path is reached only through the history view.

### Spec: claims checked and found sound

All VERIFIED unless marked.

- Sentinel split (`View.splitAroundSentinel`, View.hs lines 452-465): the sentinel row is
  rendered through `Html.text`, so user text cannot produce the raw `<tr ...>` bytes and
  cannot collide. `breakSubstring` on a miss yields the whole input and an empty tail, so the
  split is total.
- `Stream.foldFileLines` carry (Stream.hs lines 155-159): a trailing newline yields no
  phantom empty line, blank lines are kept, a final line without a newline is stepped, and a
  line across a block boundary is carried. `Bytes.split` is an index loop, not an `unpack`.
- `Stream.fileContains` carries `needle - 1` bytes across blocks, so a needle straddling a
  64 KB boundary or longer than a block is found; the empty needle is handled. It keeps
  reading after a hit rather than stopping early, which is a cost, not a defect.
- The C escaper is per-byte, so a multibyte UTF-8 sequence split across a block boundary is
  escaped identically to the whole-buffer form.
- `Iteratee.feedChunk` passes `Done` and `IterFailed` through and resolves `IterM`.
- Phase 5 404 and 409 parity: the old `showFileAtRevision` mapped failure to empty bytes, so
  the new `exit /= 0 || size == 0` predicate selects the same cases.
- Streamed page and pane headers are unchanged from the whole-render headers.
- Unit suite at HEAD: 471 examples, 0 failures under MicroHs (MEASURED).

### Spec: scope creep

Minor only. Commit 7e610bf reformats the stage table in about 35 unrelated RFCs to add a
timezone suffix. The `handleClient` totality change (2315ae4) is outside the inventory but is
recorded in the RFC (lines 430-435).

## Coding Standards Findings

Standards sources: `~/.agents/coding-standards.md`, `~/.agents/agent-design-and-test-guidance.md`,
`~/.agents/markdown-rules.md`, the repo `AGENTS.md`, and the RFC-0031 conventions (all imports
qualified, per-function Haddock in `src`). Confirmed compliant: every import qualified, British
spelling throughout, no emojis, ADR and RFC headings follow the templates. Markdown lint and
table formatting are tooling-enforced by `make docs` and are not re-reported.

### Standards hard violations

1. Orphaned Haddock. [Process.hs:190](../../packages/micro-http/src/MicroHttp/Process.hs#L190)
   keeps the "Creates a fresh, uniquely named temporary file ... Wraps `openTempFile`" block for
   `reserveTempFile`, which phase 3 deleted. It now sits between `closeFd` and `cleanup` and
   describes behaviour the module abandoned.
2. Dead code. [App.hs:2161](../../packages/verso/src/Verso/App.hs#L2161) `normaliseNewlines ::
   String -> String` has no callers; `treeSave` uses `normaliseNewlineBytes`. Its Haddock moved
   to the byte version, leaving the dead function undocumented. Delete it.
3. Missing per-function Haddock (RFC-0031):
   [Stream.hs:894](../../packages/micro-http/src/MicroHttp/Stream.hs#L894)
   `transformedFileBodyImpl`. `View.editorPage` also lacks one, but that predates the change.
4. `docs/reference/module-index.md` does not list the new `MicroHttp.Bytes`. Pre-existing:
   `MicroHttp.Process` and `MicroHttp.FileSystem` are also absent, and the `MicroHttp.Stream`
   row ("socket/file producers") is stale now that it holds `foldFileLines`, `writeFileLines`
   and `filesEqual`. No configuration keys were added, so `configuration.md` is current.
5. Public helper for one test (agent-design-and-test-guidance): `Html.coalesce` is exported and
   its only external caller is `test/unit/MicroHttp/HtmlSpec.hs`.

### Standards judgement calls (smell baseline)

1. Shotgun Surgery and Repeated Switches: adding `Http.SizedStreamBody` touched
   `serialiseResponse`, `writeResponse`, `Middleware.fuseBody`, `Middleware.logRequests` and two
   test-side body cascades. A `StreamBody (Maybe Int) enum` shape would have collapsed the sized
   and close-delimited arms in every switch. Worth a sentence in ADR-0089 if the two
   constructors are kept.
2. Duplicated Code in `Verso.App`: the guard `captureExit cap /= ExitSuccess || isNothing
   outSize || outSize == Just 0` appears three times (`treeDiff`, `treeReadAt`,
   `treeRollback`); the `readBlock -> loadPageAttachments -> breadcrumbsFor -> treeSpineFor ->
   documentPageTitle -> editorShell` sequence appears four times (`editFromFile`,
   `editFromBytes`, `treeRead`, `treeReadAt`). The second is also a Data Clump (attachments,
   breadcrumbs, spine, title travel together).
3. Duplicated test code: `materialiseBody` is copied verbatim in the integration and unit
   `AppSpec`; `resetScratch` is copied in `StreamSpec` and `FingerprintSpec`.
4. Middle Man: `Http.serialiseFileHead = serialiseSizedHead`. Keep the alias deliberately or
   retire it; the comment should say which.
5. Feature Envy: the three capture handlers reach into `Socket.fileSizeBytes` for a file size;
   `FileSystem.fileStat` is the module for that.
6. Expected error as exception: `App.storeAsset.place` throws `ioError (userError ...)` on
    rename failure; the guidance asks for typed expected errors. Borderline, since a failed
    rename after a successful write is arguably a defect.
7. `Http.decodeFormValueBytes` builds its result through a list (`BSC.pack (go 0)`), which the
    `MicroHttp.Bytes` header warns against. The KNOWN CEILING comment records it honestly.

### Standards test-coverage gaps for new public functions

- `Iteratee.feedChunk`: no direct unit test; exercised only through the integration diff test.
- `Stream.transformedTempFileBody`: the remove-on-completion and remove-on-early-stop contract
  is untested. This is also the mechanism Spec 6 depends on.
- `Git.diffBetweenCaptured`: no `GitSpec` case (the `show` variant has two).
- `Middleware.logRequests` byte counting for `SizedStreamBody`: untested.
- `treeRollback` copy-failure 500 branch: untested.
- `Html.elOpen`, `elClose`, `escapedLength`: covered only indirectly.
- Test naming: the `foldFileLines` cases omit the "when" clause of the given/when/then form.

## Review Summary

Spec axis: 7 findings. The worst is Spec 1, a 1 MiB attacker-controlled body still parsed as
`String` in `treeImageTitles`, the exact shape the RFC measured as non-terminating. Spec 2
(strict `unpack` under MicroHs on the publish path) is the least obvious and contradicts a
comment in the code. No byte-identity claim failed.

Standards axis: 12 findings plus 7 coverage gaps. The worst are the orphaned Haddock in
`Process.hs` and the dead `normaliseNewlines`, both hard violations of RFC-0031 and both
trivial to fix. The rest are judgement calls, of which the four-fold `editorShell` assembly
sequence in `Verso.App` is the one most worth acting on.

## Remediation Summary

Applied on 2026-09-13, on `main`, after the review above. The baseline before the changes was green
(lint, format check, mhs unit 471 and integration 119). Every finding is listed with what was done; a
finding left as recorded says why.

### Spec Findings Remediated

- **Spec 1, `treeImageTitles`.** `formFields` now takes the body as bytes and unpacks only the decoded
  fields, and every caller passes bytes (the `BS.unpack bodyBytes` at each site is gone). The handler's cap
  moved from `formBodyLimit` (1 MiB) to a new `imageTitlesBodyLimit` of 64 KiB, since the body carries
  indexed paths and short titles and never a document. This is a contract change for that one endpoint;
  hundreds of images still fit. An integration test posts a body one byte over the cap and expects the
  too-large failure.
- **Spec 2, publish message.** `publishMessage` takes the document as bytes, slices the leading frontmatter
  block with `Frontmatter.slice` (a bounded block, never the body) and decodes only that. The wrong "unpack is
  lazy" comment is gone. The title is now UTF-8 decoded, as `documentPageTitle` already did; before, a
  non-ASCII title reached git double-encoded. An integration test publishes a page named `Café Notes` and
  expects that subject on the commit. The test was written against the new behaviour and is expected to fail
  on the old path by reasoning about the encoding, not by running it against the old build.
- **Spec 3, draft edit view.** `treeEdit` checks `Draft.hasDraft` and streams the staging file through
  `documentFileResponse` like a published page; `documentBytesResponse` now serves only the new-page seed
  and its Haddock says so. `Draft.readDraft` stays for its own tests. The existing draft-resume integration
  test covers the path.
- **Spec 4, ADR-0090.** A dated addendum records that phase 9 streamed `treeDiff` and that only `treeReadAt`
  reads the frontmatter block. RFC-0040's phase-5 deferral now says phase 9 superseded it. ADRs are
  append-only, so the original text stands with the addendum below it.
- **Spec 5, RFC-0041.** `related_refs` is empty; the three prose mentions of the spike name its branch.
- **Spec 6, cleanup windows.** `treeReadAt` builds its response under `onException`, removing the stdout
  capture if the chrome loading crashes before the streaming body owns it. `Stream.writeFileLines` closes
  its handle under `finally`. `LinkIndexStore.persistState` removes the `.tmp` when the write fails. The
  first two have no test: neither failure can be provoked from a test without a fault-injection seam.
- **Spec 7, per-line `String` in the streamed diff.** Left as recorded. Moving `SideRow` to bytes needs an
  escaped-bytes cell renderer in `IO` and would turn the pure scan step into an effectful one; the bound is
  one diff line, on a history view, and the change is not worth that shape today.

### Standards Findings Remediated

- Orphaned Haddock in `Process.hs` removed. Dead `normaliseNewlines` removed. `transformedFileBodyImpl` has
  its Haddock.
- `module-index.md` gains `MicroHttp.Bytes`, `MicroHttp.FileSystem` and `MicroHttp.Process`, and the
  `MicroHttp.Stream` row names the file folds, scans, writers and comparisons.
- `Html.coalesce` stays exported. The lazy-versus-strict oracle tests are the contract that ADR-0089's
  "coalesce is lazy" consequence rests on, and they need the buffer size as a parameter; the export is kept
  as a documented, tested contract rather than a test-only helper.
- The two-constructor `SizedStreamBody` shape stays; ADR-0089 gains an addendum saying why.
- The repeated capture guard is one `captureEmpty`, which reads the size through `FileSystem.fileStat`
  (the module for it) rather than `Socket.fileSizeBytes`. The four-fold chrome assembly is one
  `pageChrome` returning a `PageChrome` record and one `shellFor` that hands it to `View.editorShell`.
- `materialiseBody` and `resetScratch` live once each in a new `test/support/TestSupport` tree, on the
  search path of all four test builds and of hlint.
- `Http.serialiseFileHead` is retired; its callers use `serialiseSizedHead`.
- `storeAsset` returns `Either` instead of throwing; the upload handler answers 500 and the temp is removed.
- `decodeFormValueBytes` keeps its list-built result, as recorded in its own comment.

### Coverage Added

- `Iteratee.feedChunk`: five unit cases (waiting consumer, `Done` and `IterFailed` pass-through, `IterM`
  resolution, empty chunk).
- `Stream.transformedTempFileBody`: removal on completion, on early stop, and the missing-file error.
- `Middleware.logRequests` counts a `SizedStreamBody` as the sized head plus the body bytes.
- `Git.diffBetweenCaptured`: the capture holds the unified diff and both files are the caller's to remove.
- The `foldFileLines` case names carry a "when" clause.
- Still untested: the `treeRollback` copy-failure 500 branch and the two `finally`/`onException` paths above.

### Verification

| Check                         | Result                                                                                                                   |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `make lint format-check`      | clean                                                                                                                    |
| `make test-unit` (mhs)        | 480 examples, 0 failures (was 471)                                                                                       |
| `make test-integration` (mhs) | 122 examples, 0 failures (was 119)                                                                                       |
| `make check`                  | green: docs, format, lint, mhs and GHC suites (480 unit, 122 integration each), editor checks, both smokes, chrome gates |
