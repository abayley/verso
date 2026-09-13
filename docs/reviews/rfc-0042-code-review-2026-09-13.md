# RFC-0042 code review: the streaming form consumer and the RFC-0040 follow-ons

Status: review (2026-09-13). Change set `03794ea..2704f26` on `main` (RFC-0040 remediation
and close, the streamed raw PUT bodies, RFC-0042 phases 1-3, ADR-0092, the `socketSinkFile`
size fix). 39 files, about 1990 insertions and 420 deletions.

The review ran along the two usual independent axes, each in its own sub-agent: Spec (does the
code do what RFC-0042 and ADR-0092 say, and are the documents accurate) and Standards (does the
code follow the documented conventions and avoid the Fowler smell baseline). The handoff also
named five correctness questions about the hand-rolled parser and the sinks; a third sub-agent
desk-traced and executed those under GHC, and its findings are kept in their own section. The
sections are not reranked against each other. Each finding is labelled MEASURED (a command or
probe was run), VERIFIED (the code was traced end to end) or INFERRED (a plausible reading not
confirmed by execution).

Baseline for the review: the MicroHs unit suite at HEAD passes (496 examples, 0 failures,
MEASURED). The GHC suites, the smokes and the full `make check` were not rerun; the handoff
records them green at HEAD. The parser probes live in the session scratchpad and were not
added to the tree.

## RFC-0042 Correctness Findings

Ranked by severity. Resource-cleanup regressions are the top class; no byte-identity claim
failed.

### Correctness 1: a transport failure mid-part never reaches the routed sink

MEASURED (probe against `MicroHttp.Form` under GHC), VERIFIED in the app.

`inValue` in [Form.hs:115](../../packages/micro-http/src/MicroHttp/Form.hs#L115) handles
`EndOfStream (Just err)` by returning `IterFailed err s` at once. The part that was being
streamed is dropped without ever seeing an end of stream. With a routed sink open and a failed
end fed, the probe recorded that the sink saw no end at all. In `formSaveSink`
([App.hs:1676](../../packages/verso/src/Verso/App.hs#L1676)) that sink is `Stream.fileSinkI`,
whose close-and-remove path ([Stream.hs:335](../../packages/micro-http/src/MicroHttp/Stream.hs#L335))
therefore never runs when a client disconnects or times out while the `markdown` field is
streaming. `sinkToFile`'s `onFailure discard` unlinks the temp, but the write handle stays
open: finalised by the GC under GHC, and under MicroHs most likely a permanent fd per aborted
no-JS save. `FormSpec`'s transport-failure test uses a collected field, so it does not pin this.

Fix: on `EndOfStream (Just err)` deliver the failed end to the part (an `IterM` around
`endWith`-style delivery to the part's iteratee) and only then fail the form. Add a
`FormSpec` case with a routed sink that records whether it saw an end.

### Correctness 2: `onFailure` sees `IterFailed` values, not exceptions

MEASURED.

[Iteratee.hs:261](../../packages/micro-http/src/MicroHttp/Iteratee.hs#L261) walks `IterM`
with `fmap go`, so an `IterM` action that throws bypasses the cleanup. A write error in
`fileSinkI` (disk full) propagates to the server's `Exception.try` and becomes a handler crash,
leaving the `.save-*` temp on disk and the handle open. The same applies to a throw between
sink resolution and rename in `sinkToFile`
([App.hs:1740](../../packages/verso/src/Verso/App.hs#L1740)). `writeFileLines` documents its
"leaves a partial file" behaviour; this path does not. Low likelihood, but it is exactly the
class the RFC-0040 review's coverage list left open (the `finally`/`onException` paths).

Fix: either wrap the `IterM` in `onFailure` with `Exception.onException cleanup`, or state in
the Haddock that exceptions are out of scope and the temp is left for the next start-up sweep.

### Correctness 3: failure residues are inconsistent; the Haddock overclaims

MEASURED. See also Spec 1, which reports the same thing from the spec side.

Value-cap failure carries the rejected decoded bytes as residue (the unread `&b=2` is lost),
name-cap failure carries `Chunk ""` ([Form.hs:98](../../packages/micro-http/src/MicroHttp/Form.hs#L98)),
and a routed-sink failure carries whatever the inner returned. Nothing reads the residue: every
error response carries `Connection: close` and `Server` never resumes the stream. Cosmetic today,
but the Haddock at [Form.hs:56](../../packages/micro-http/src/MicroHttp/Form.hs#L56) promises
"the unread bytes as residue" and the RFC's routing test 2 says the same.

### Correctness 4: `Socket.fileSize` is unchecked

INFERRED; not a regression of `1f1f3c1`.

An `lseek` returning -1 becomes `Content-Length: -1` and `sendFileLoop` returns at once
because the remaining count is not positive. Only reachable for a non-seekable served path.

### Correctness 5: the access log can disagree with the wire

VERIFIED. This answers handoff question 4.

[Middleware.hs:157](../../packages/micro-http/src/MicroHttp/Middleware.hs#L157) logs the
`FileBody`'s carried size while [Server.hs:240](../../packages/micro-http/src/MicroHttp/Server.hs#L240)
sends the fd's size for both the head and the `sendfile` length, so the two agree except when
the file was replaced between the handler and the send. That is the case the fix exists for,
and the commit message calls the log staleness intended. Growth after the `lseek` is harmless
(exactly `size` bytes go out); in-place truncation yields a short body, which `sendFileWithin`
already documents. Recommendation: accept the stale log. The carried size still earns its keep
only as a log value and as the value the test adapter honours; see Standards 2 for the
documentation debt this leaves.

### Correctness: checked and found sound

All MEASURED by probe unless noted.

- Wire semantics match the removed `parseFormBody` and `decodeFormValueBytes`: `a=1&` yields a
  trailing empty field, the empty body yields nothing, `&&` yields three empty fields, `a&b=2`,
  `=v`, `+` in names and values, escapes and names split across one- and two-byte chunks, and
  both advance by three on a malformed escape.
- Name cap on the accumulated name across chunks; value cap across chunks; total cap across
  fields; `maxFields` counts routed parts. Exactly at the cap is accepted everywhere. `FormSpec`
  does not pin the boundary values.
- `formFieldsI`'s count cap of cap plus one fires only for all-empty bodies, where the total cap
  cannot; consistent with its Haddock.
- A routed sink that resolves early: later bytes are dropped by `feedChunk` and the parser keeps
  scanning for `&`, so the following field is still collected. A routed sink that fails
  mid-part: the failure is propagated unchanged.
- `decodeBlock`'s cut and scan agree on `%%2`, `%2%`, `%2%20`, `%%20`, `%zz%41`, `a%`, `%`, `%4`,
  a `%` at byte 4095 of a slice, `%4|1` across the slice boundary, blocks of 4096 and 4097 bytes,
  and a 14,700-byte adversarial string at chunk sizes 1, 2, 3, 5, 7, 4095, 4096, 4097 and whole.
- `transformI` stops early mid-slice with the inner's `Done` and residue; `endWith` walks `IterM`.
- `onFailure` runs once for a failure at construction and once for an input failure, never on
  success.
- `sinkToFile` creates the temp empty first, renames only after the consumer resolves, removes
  on consumer failure and on rename failure; `uniqueTempPath` is per thread plus a stat probe, so
  concurrent saves of the same page take distinct temps (VERIFIED).
- `fileSinkI`'s own cap failure closes and removes the temp; the later `discard` is a harmless
  ENOENT.

## RFC-0042 Spec Findings

Ranked by severity.

### Spec 1: cap failures discard the residue the spec and Haddock promise

VERIFIED.

RFC-0042's routing test 2 reads "consumer fails with the supplied error and the residue is
preserved", and the `formI` Haddock repeats it. The code returns `Chunk BS.empty` at
[Form.hs:98](../../packages/micro-http/src/MicroHttp/Form.hs#L98), 146, 151, 164 and 168; only
the name-decode failure keeps the rest of the chunk. `FormSpec` lines 124-135 assert the error
only. Fix the code or drop the claim from both documents (Correctness 3 recommends dropping it,
since nothing consumes a residue).

### Spec 2: `maxCollectedBytes` ignores names, so the phase-3 count-cap reasoning is false

VERIFIED.

The Proposal defines `maxCollectedBytes` as "decoded bytes across all collected fields" and the
phase-3 note says `formFieldsI`'s "count cap is the cap plus one, which the bytes already
imply". `recordField` ([Form.hs:162](../../packages/micro-http/src/MicroHttp/Form.hs#L162)) adds
the value length only. For `formFieldsI cap` ([App.hs:2250](../../packages/verso/src/Verso/App.hs#L2250))
a body of 8193 fields each with an 8 KiB name and an empty value is accepted and holds about
64 MiB of names; only the framework's 10 MiB `max_body_bytes` bounds it. Low practical risk,
but the RFC's Security Impact bullet overstates the bound. Fix: count name bytes in the total,
or reword the RFC.

### Spec 3: a duplicate `markdown` field now takes the last value, not the first

VERIFIED; an unrecorded behaviour change.

The removed `captureBytes` returned the first match. The new `route`
([App.hs:1676](../../packages/verso/src/Verso/App.hs#L1676)) builds a fresh `fileSinkI` in
`WriteMode` per `markdown` part, so a second occurrence truncates and replaces the first. The
RFC's Compatibility section does not mention it. The browser form cannot produce it, so record
it rather than change it.

### Spec 4: the configuration reference is stale and incomplete

VERIFIED.

[configuration.md:45](../reference/configuration.md#L45) still says "the no-JS form's remaining
whole-body read is RFC-0042's" in a tree where RFC-0042 is Implemented. The table's values match
the code (`formBodyLimit`, `treeAssetMaxBytes`, `imageTitlesBodyLimit`, `treeCreateMaxBytes`,
`clientErrorMaxBytes`), but `saveFormLimits` (8 KiB per field, 64 KiB collected, 64 parts at
[App.hs:1683](../../packages/verso/src/Verso/App.hs#L1683)) is a ceiling the form now enforces
and is not catalogued.

### Spec 5: the versioning-on form save is only tested with a 20-byte body

VERIFIED.

Integration test 3 asks for "when a form save is posted, then the draft is staged from the
stream". The only versioning-on form POST ([AppSpec.hs:360](../../test/integration/Verso/AppSpec.hs#L360))
predates the RFC and posts 20 bytes; the larger-than-a-chunk form test at line 132 runs
versioning-off only. Tests 1, 2 and the field-cap test are present and match.

### Spec 6: three RFC test-list entries have no named case

VERIFIED.

Parser 6 (`&` and `=` at a chunk boundary) and the newline "CR at chunk end, LF at next start"
case are covered only implicitly by the chunk-size sweep. Routing 5 ("fails on its second
chunk") is tested with a sink that fails on its first chunk. Decoder 7 (above the old 350 KB
ceiling) exists as the 1 MiB cases.

### Spec: cap values against what the editor posts

VERIFIED for the payload shapes, INFERRED for the limit. The editor's save and image-title
requests fit the 8 KiB and 64 KiB caps for realistic sizes. One consequence of the
`imageTitlesBodyLimit` change made during the RFC-0040 remediation: 1000 entries, the
`maxImageTitleEntries` guard at [App.hs:2026](../../packages/verso/src/Verso/App.hs#L2026),
cannot fit in 64 KiB, so that guard is now unreachable. Either lower the entry cap to match or
note that the byte cap subsumes it.

The handoff's judgement call, an empty-page save when the form has no `markdown` field versus
a 400: keeping parity with the old parser is defensible and is what the RFC records. A 400
would be the stricter contract, but the only producer is the server's own form, which always
has the field. Leave it, and say so in the RFC's Open Questions.

### Spec: everything else checked

VERIFIED. ADR-0092's contract, field-order rule (the textarea is the only field, and the
comment in `View.hs` says why), and producer-chunk slicing rule all match the code. No
`readBodyStrict`, `parseFormBody` or `captureBytes` remains on a form path. `formFieldsI` is the
all-collect `formI`. `maxFields` counts routed parts as the phase-1 note records. The
module-index row matches `MicroHttp.Form`'s exports. Every claim in the RFC-0040 remediation
summary is in the tree. The scope beyond the RFC text (`Iteratee.onFailure`, `transformI`
slicing, the fourth integration test, the `socketSinkFile` size fix) is each recorded in the
RFC; Spec 3 is the one unrecorded change.

## Coding Standards Findings

Tooling: `markdownlint-cli2` and `md-table-format --check` pass on the four new or changed
documents (MEASURED). No US spellings in the added code or prose. Every new top-level binding in
`src/` has Haddock. ADR and RFC headings follow the templates.

### Standards 1: four unqualified imports in the tests

VERIFIED, hard violation of the RFC-0031 convention (every import qualified with an alias,
Prelude and Test.Hspec exempt).

- [test/integration/Verso/AppSpec.hs:17](../../test/integration/Verso/AppSpec.hs#L17) and
  [test/unit/Verso/AppSpec.hs:14](../../test/unit/Verso/AppSpec.hs#L14) import
  `TestSupport.ResponseBody (materialiseBody)` unqualified.
- [test/unit/MicroHttp/StreamSpec.hs:10](../../test/unit/MicroHttp/StreamSpec.hs#L10) and
  [test/unit/Concordance/FingerprintSpec.hs:8](../../test/unit/Concordance/FingerprintSpec.hs#L8)
  import `TestSupport.Scratch (resetScratchDir)` unqualified.

There was no prior `TestSupport` import to set a precedent either way. Fix: qualify them.

### Standards 2: the `FileBody` record documentation is stale after `1f1f3c1`

VERIFIED, interface documentation.

[Http.hs:399](../../packages/micro-http/src/MicroHttp/Http.hs#L399) says a `FileBody` "is
delegated whole to `sinkFile` with its path and pre-resolved size", but the socket adapter now
ignores that size and re-seeks, while the test adapter in `ResponseFileSpec` still honours it.
The two adapters of one seam disagree on what the `Int` means. State that the size is advisory
(access log only) or remove it from the sink signature (Standards 3).

### Standards 3: `sinkFile` carries a parameter its real adapter ignores

VERIFIED, Speculative Generality (judgement call). `Server.sinkFile` binds the size as
`_resolvedSize`. Either drop it from `ResponseSink` (the log already reads it from the
`FileBody`) or document it per Standards 2.

### Standards 4: `withNameBytes` passes a value no caller uses

VERIFIED, judgement call. [Form.hs:97](../../packages/micro-http/src/MicroHttp/Form.hs#L97)
passes `totals` to its continuation and all three callers write `\_ ->`. Make the continuation
a plain iteratee.

### Standards 5: duplicated shapes in `Form.hs`

VERIFIED, judgement call. The `decodeFormValueI (readBodyStrict ...)` collector is spelled out
at lines 101 and 106; `Left err -> IterFailed err (Chunk BS.empty)` appears four times. The
name accumulator rebuilds `BS.concat (reverse (bytes : acc))` on every chunk while a name is
being read, which is quadratic in chunk count. It is bounded by `maxFieldBytes`, so acceptable,
but worth a comment.

### Standards 6: `formI`'s working-memory load

VERIFIED, judgement call against the function design rules. `formI` is about 110 lines of
mutually recursive local closures in continuation-passing style carrying totals, accumulator,
pending flag, part and continuation. Lifting the `Totals` and `Part` transitions to top-level
functions over a named state would reduce the load without changing behaviour, and would make
the fix for Correctness 1 easier to see.

### Standards 7: the form result tuple wants a name

VERIFIED, Primitive Obsession (judgement call). `formI` returns a pair of association lists and
`formSaveSink` restates the type. A small record with `collected` and `routed` fields would name
it once.

### Standards 8: three adjacent booleans in `shellFor`

VERIFIED, Data Clump (judgement call, pre-existing shape). `shellFor path request versioned
editable hasDraft chrome` inherits the flags from `View.editorShell`; `PageChrome` was the right
step and the flags could join it.

### Standards 9: duplicated small shapes in `App.hs` and the tests

VERIFIED, judgement calls.

- `drainBody >> pure treeNotFound` appears five times in `App.hs` (lines 1098, 1607, 1609, 1645,
  1704); `Left _ -> pure saveFailed` twice.
- `FormSpec` repeats the map-then-compare-against-the-oracle helper three times.
- The integration `AppSpec` adds six local `head = "POST ..."` bindings that shadow Prelude's
  `head`; rename to `requestHead`.
- `StreamSpec`'s "temp path that does not exist" asserts only that the result is a `Left`, not
  which error.

## Review Summary

| Axis        | Findings | Worst                                                                  |
| ----------- | -------- | ---------------------------------------------------------------------- |
| Correctness | 5        | Correctness 1: a mid-part transport failure leaks the file sink handle |
| Spec        | 6        | Spec 1: cap failures drop the residue the spec and Haddock promise     |
| Standards   | 9        | Standards 1: four unqualified imports against the RFC-0031 convention  |

Correctness 1 is the one finding that warrants a code change before the RFC is left closed:
it is a resource leak on a real client path, and it is untested. Correctness 2 and Spec 1 are
documentation or contract choices that should be made explicitly. The rest are cleanups and
record-keeping. Nothing here reopens the byte-identity claims: the streaming parser agrees
with the retired one on every probed input.

## Remediation Summary

Applied 2026-09-13, after the review above. `make check` is green under both compilers: unit 504 (was
496), integration 130 (was 129), both editor smokes and the chrome gates (MEASURED). Nothing is
committed.

### Correctness remediation

- **Correctness 1, mid-part transport failure.** `formI`'s value state now hands a failed end of stream
  to the part being streamed (`Form.abandonPart`, over the newly exported `Iteratee.feedStream`) and
  resolves it before failing the form, so `fileSinkI` closes and removes its temp. A `FormSpec` case
  drives a routed sink through a failed end and asserts the sink saw it.
- **Correctness 2, exceptions in `onFailure`.** The `IterM` step is wrapped in `Exception.onException
  cleanup`, so a throwing effect step runs the cleanup once and rethrows; the Haddock says so. An
  `IterateeSpec` case throws from an effect step and checks the count and the propagated error.
- **Correctness 3 and Spec 1, the residue contract.** Decided for the documents: the residue of a failed
  form is not meaningful, because the server answers the error and closes the connection without resuming
  the stream. The `formI` Haddock, the RFC's Proposal and its routing test 2 now say that; every internal
  failure goes through one `failWith`.
- **Correctness 4, unchecked `lseek`.** `socketSinkFile` treats a negative size as a source error and
  aborts the connection instead of writing a negative `Content-Length`.
- **Correctness 5, stale access log.** Accepted as intended; recorded on the `ResponseSink` and
  `socketSinkFile` Haddocks (see Standards 2).

### Spec remediation

- **Spec 2, names in the total cap.** `recordField` counts the name and the value; `FormLimits`'s Haddock,
  the RFC's `FormLimits` sketch, its Security Impact bullet and the phase-3 note were corrected, and the
  `formFieldsI` Haddock now states what the count cap is for (a run of empty fields, which add no bytes).
  A `FormSpec` case pins names alone exceeding the total.
- **Spec 3, duplicate `markdown` field.** Recorded in the RFC's Compatibility Impact and the
  `formSaveSink` Haddock: last wins, each routed part opens the temp afresh, the browser form has one.
- **Spec 4, configuration reference.** The stale sentence is rewritten and a `saveFormLimits` row added
  to the ceilings table.
- **Spec 5, versioning-on form save.** A new integration test posts a form larger than any stream chunk
  with versioning on and checks the draft's bytes, the untouched live page and the absence of a temp.
- **Spec 6, named test gaps.** `FormSpec` gains named cases for `=` and `&` at chunk edges (`feedPieces`),
  a CR ending one chunk with its LF starting the next, a routed sink failing on its second chunk, and the
  per-field cap boundary for a value and for a name fed a byte at a time.
- **Image-title entry cap.** No change. The sub-agent's inference was wrong: with empty paths an entry is
  under 30 bytes, so a thousand entries fit in 64 KiB, and the guard bounds the loop `image_count` drives,
  not the body. Left as is.
- **Empty-page parity.** Decided to keep it; the reasoning is recorded under the RFC's Open Questions.

### Standards remediation

- **Standards 1.** The four `TestSupport` imports are qualified.
- **Standards 2 and 3.** `sinkFile` no longer takes a size; the socket adapter and both in-memory test
  adapters size what they open, and the `ResponseSink` Haddock states that a `FileBody`'s carried size
  serves only the access log.
- **Standards 4.** `withNameBytes` became `withinNameCap`, which takes a plain iteratee.
- **Standards 5.** One `cappedCollector`, one `failWith`; the name accumulator now checks the summed
  length of its chunks as it grows and concatenates once when the name ends, so the per-chunk
  concatenation is gone.
- **Standards 6.** `recordField`, `countPart`, `finished`, `feedPart` and `abandonPart` are top-level
  functions over `Totals` and `Part`; the `where` block keeps only the parser states.
- **Standards 7.** `formI` returns a `FormResult` record with `collectedFields` and `routedResults`;
  `formSaveSink`, `formFieldsI` and `FormSpec` use it.
- **Standards 8.** Not changed. The three flags are the signature of `View.editorShell`, which predates
  this change set; folding them into `PageChrome` means changing the view layer and its tests, which is a
  separate refactor rather than a remediation of this RFC.
- **Standards 9.** `notFoundAfterDrain` replaces the five repeated drains; `FormSpec` compares against its
  oracles through one `agreesWithOracle`; the integration `AppSpec`'s `head` bindings are `requestHead`;
  `StreamSpec`'s absent-temp case asserts the exact `StreamSourceError`.
