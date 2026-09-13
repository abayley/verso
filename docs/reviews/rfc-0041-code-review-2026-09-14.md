# RFC-0041 code review: multi-source iteratees

Status: review (2026-09-14). Change set: the uncommitted working tree on `main` against
`d18e23b` (the RFC-0042 review and remediation). 14 files, about 400 insertions and 130
deletions: `MicroHttp.Iteratee` generalised to `IterT e m`, `runNested2`, `headChunk`,
`filesEqual` rewritten as a two-source consumer, the new unit cases, the bench harness repair,
the RFC moved to `implemented/`, ADR-0091 amended, the module and RFC indexes.

The review ran along the two usual independent axes, each in its own sub-agent: Spec (does the
code do what RFC-0041 and ADR-0091 say, and are the documents accurate) and Standards (does the
code follow the documented conventions and avoid the Fowler smell baseline). The handoff named
five correctness questions about `runNested2`, `filesEqual` and the bench programs; a third
sub-agent desk-traced and executed those with GHC probes against the modules, and its findings
are kept in their own section. The sections are not reranked against each other. Each finding
is labelled MEASURED (a command or probe was run), VERIFIED (the code was traced end to end)
or INFERRED (a plausible reading not confirmed by execution).

Baseline for the review, all MEASURED on the working tree: `make format-check` and `make lint`
pass; the MicroHs unit suite passes (516 examples, 0 failures). The GHC suites, the smokes and
the full `make check` were not rerun; the handoff records them green at the end of the
implementing session. The probes live in the session scratchpad and were not added to the tree.

## RFC-0041 Correctness Findings

Ranked by severity. Two findings are contract breaches in the new driver, both reachable from
`filesEqual`; the RFC's own test lists did not cover either path.

### Correctness 1: an outer acquire failure is silently turned into an orderly end

MEASURED (GHC probe), VERIFIED in the code and both app callers.

`resourceEnumerator` handles a failed acquire with `feedAcquireError`
([Iteratee.hs:272](../../packages/micro-http/src/MicroHttp/Iteratee.hs#L272)), which delivers
the error only when the iteratee is already `NeedInput` and returns anything else untouched.
This predates the change, and at the base layer it was sufficient: consumers start waiting for
input. Under `runNested2` the outer-layer iteratee is `inner consumer >>= run`, and it always
starts as `IterM`, because the inner enumerator's first step is its own lifted acquire. So the
outer enumerator's acquire error is dropped, and when the consumer later lifts `headChunk` the
base `run` ([Iteratee.hs:130](../../packages/micro-http/src/MicroHttp/Iteratee.hs#L130)) feeds
`EndOfStream Nothing`. The probe with a failing outer acquire returned
`Right (Just "one", Nothing)`, not a `Left`.

For `filesEqual` ([Stream.hs:358](../../packages/micro-http/src/MicroHttp/Stream.hs#L358))
this means a second file that stats but does not open (a permission change, a directory
swapped under the name) yields a verdict instead of the failure the Haddock promises:
`Right False` for non-empty files and `Right True` for two zero-size files. The old loop
returned `Left "cannot open file: pathB"`. The RFC's goal of a byte-for-byte identical verdict
is therefore not met on this path.

In `App.storeAsset`
([App.hs:1168](../../packages/verso/src/Verso/App.hs#L1168)) `Right False` moves on to the
next candidate name, which is safe; `Right True` removes the uploaded temp and reports the
unreadable existing file as the de-duplicated asset, which loses the upload. In
`TreeMove.assetConflicts`
([TreeMove.hs:363](../../packages/verso/src/Verso/TreeMove.hs#L363)) `Right False` refuses
the move, which is safe; `Right True` lets the move proceed and reuse a destination it could
not read. Both unsafe outcomes need zero-size assets, so the likelihood is low, but the
direction is wrong.

Fix: make `feedAcquireError` drive `IterM` steps until the iteratee is `NeedInput` (as
`strictEnumerator` and the enumerator's own loop already do) and then deliver the failed end.
Add a `StreamSpec` case with a second file that stats but cannot be opened (a directory in
place of the file is the portable way to get there), asserting `Left` with the open error.
Add an `IterateeSpec` case for the outer acquire failure under `runNested2`.

### Correctness 2: the inner resource leaks when the outer stream fails

MEASURED (GHC probe), VERIFIED.

The inner `resourceEnumerator` runs with base monad `IterT e IO`, so its `IterM` branch
([Iteratee.hs:284](../../packages/micro-http/src/MicroHttp/Iteratee.hs#L284)) is a bind in the
outer iteratee. When the consumer lifts `headChunk` and the outer stream delivers
`EndOfStream (Just err)`, that step resolves to `IterFailed` at the outer layer, the outer
bind short-circuits ([Iteratee.hs:92](../../packages/micro-http/src/MicroHttp/Iteratee.hs#L92)),
and the rest of the inner enumerator's `do` block, including the release, never runs. Probe:
counted inner resource, failing outer enumerator, consumer `headChunk >> lift headChunk`
gave `Left Boom` with zero inner releases. The outer enumerator does release its own resource.

The handoff's expectation that "the inner enumerator has already returned by the time the
outer runs" is wrong: the two enumerators interleave, because the outer drives the layer
whose effect steps are the inner enumerator's steps. The `runNested2` Haddock
([Iteratee.hs:145](../../packages/micro-http/src/MicroHttp/Iteratee.hs#L145)), the RFC's
Reliability Impact and the amended ADR-0091 all state that both sources are released however
the consumer stops. That is false as stated.

Exposure through `filesEqual` today is low: `fileEnumeratorChunked` only produces a failed end
on acquire, and that case is masked by Correctness 1. Once Correctness 1 is fixed, an
unopenable second file would leak the first file's handle by this path, so the two must be
fixed together. The existing base-layer failure test
([IterateeSpec.hs:122](../../test/unit/MicroHttp/IterateeSpec.hs#L122)) uses
`strictEnumerator` for the inner stream and cannot see this.

Fix options, in order of preference: have `resourceEnumerator`'s `IterM` branch inspect the
result of `m` for failure before looping and release on that path, which needs the step to
be run through a helper that catches the layer's `IterFailed` rather than a plain bind; or
document that the inner bracket is released by the outer `run` only on orderly ends and have
`runNested2` state the restriction. The first keeps the contract the docs already make. Add
the asymmetric test (counted inner, failing outer) to `IterateeSpec`.

### Correctness 3: two of the three bench programs do not compile

MEASURED with the exact `mhs -a$DB -itest/bench` line the repaired scripts use.

`IterateeReceiver` builds. `EgressSender.hs:63` and `SocketReceiver.hs:34` still match
`Right client ->` against `accept`, which returns a pair
([Socket.hs:169](../../packages/micro-http/src/MicroHttp/Network/Socket.hs#L169)), and fail
to type check. The diff fixed the same pattern in `IterateeReceiver` only, so
`egress-bench.sh` and `socket-saturated-bench.sh` cannot run. The RFC's Findings section
records the receiver repair as if the harness were whole again.

Fix: apply the same `Right (client, _) ->` change to both files and run each script once, or
record in the RFC that only `iteratee-bench.sh` was repaired.

### Correctness 4: the outer bracket does release when the inner consumer fails

MEASURED. Counted outer resource, inner consumer failing after one inner chunk and after one
chunk from each stream: one outer release in both cases. The code is correct here. A test is
cheap and worth adding alongside the asymmetric one from Correctness 2, since the two together
pin the contract from both sides.

### Correctness 5: block alignment in `filesEqual` holds for the callers

VERIFIED. The size check precedes the compare. GHC's `hGet` fills to the requested count or
end of file; MicroHs's `hGet` is a single `fread` of that count, which stdio also loops to the
count or end of file. Equal-size regular files therefore deliver aligned blocks. A FIFO stats
at size zero, and both callers guard with `doesFileExist` on tree paths. A concurrent append can
only produce a spurious `False`, which is the safe direction for both callers. ByteString
equality on MicroHs is a primitive, not an unpack.

### Correctness 6: the remaining handoff questions

VERIFIED. `Monad.join` on `Either e (Either e a)` is `either Left id`, and neither layer's
`Left` can mask the other's: an inner `Left` arrives at the outer layer as `Done (Left e)` and
nothing reads the outer stream after that. The `MonadIO (IterT e m)` instance and the
`liftIO` and `lift` re-exports are sound. Nothing in `headChunk` or `equalBlocks` builds a
per-chunk list. Not verified: Haskell exceptions from `hGet` inside either layer; the
enumerator has no `bracket`, so they leak both handles at any layer. That is pre-existing and
was recorded against `onFailure` in the RFC-0042 review.

## RFC-0041 Spec Findings

Ranked by severity within this section.

### Spec 1: the open-failure path of `filesEqual` regresses and is untested

VERIFIED; the mechanism is Correctness 1. Phase 3 test 8 reads "A missing second file is a
failure, not a verdict (existing, with the exact error asserted)". The case at
[StreamSpec.hs:240](../../test/unit/MicroHttp/StreamSpec.hs#L240) asserts a prefix of the
stat error only, so the open path is never exercised, and the RFC's goal of an unchanged
verdict is not met on it.

### Spec 2: the release-on-every-exit claim is not met

VERIFIED; the mechanism is Correctness 2. The RFC's Reliability Impact and the `runNested2`
Haddock both claim both handles are closed on every exit path. Phase 2's failure tests fail the
inner layer only; Phase 1 test 5 fails the base layer with no resource on the inner.

### Spec 3: the Proposal still shows the spike's shapes

VERIFIED. The Proposal shows `enumFile` with `toBase`, `runZip2` and `runZip3`, `headMaybe`,
`equalZip`, `flatten`, and `type Zip a = IterT ByteString (IterT ByteString IO) a`, whose first
parameter reads as the element type where the implementation's first parameter is the failure
type. "Decision to proceed" names the differences, but a reader of the Proposal alone is
misled. A one-line pointer at the top of the Proposal to the implemented names
(`resourceEnumerator` and `fileEnumeratorChunked` under `MonadIO`, `runNested2`, `headChunk`,
`equalBlocks`) is enough.

### Spec 4: a stale checklist item and missing Done notes

VERIFIED. The Phase 1 checklist ticks "`onFailure` generalised to `Monad m` or `MonadIO m`",
but `onFailure` stays at `IO`
([Iteratee.hs:337](../../packages/micro-http/src/MicroHttp/Iteratee.hs#L337)), as the Findings
section says. The template's Phase Item Completion Instructions ask for a dated Done note on
each item that deviated; none is present, the deviations live only in Findings. Minor.

### Spec 5: the bench record

INFERRED. The Python-sender caveat and the single cold "before" run are stated plainly, which
is honest. But the checklist says `make bench-iteratee` before and after, and the script still
builds the GHC sender with output silenced, so the target as committed did not produce those
numbers and the GHC half of the repair is unverified. With Correctness 3, the accurate record
is: one of three scripts repaired, and its numbers obtained with a sender outside the tree.

### Spec 6: scope and deviations

VERIFIED. The bench repair, the `compareBlockBytes` export and the `Iter (..)` to `IterT (..)`
import change are all recorded in Findings. `MonadIO` in place of the rank-2 argument is
settled in "Decision to proceed" and applied consistently across `resourceEnumerator`,
`byteSinkI` and `fileEnumeratorChunked`. `headChunk` skipping empty chunks is unrecorded and
harmless. The module index row, the RFC index row and the ADR-0091 rewrite match the code
names; the ADR's "closed however the compare stops" inherits Spec 2.

## RFC-0041 Standards Findings

No new hard violations. Everything below is a touched-but-not-fixed pre-existing line or a
judgement call.

### Standards 1: unqualified imports in the touched bench files

Hard rule (RFC-0031), pre-existing. The diff edits the `import MicroHttp.Iteratee (...)` lines
in [EgressSender.hs:18](../../test/bench/EgressSender.hs#L18) and
[IterateeReceiver.hs:23](../../test/bench/IterateeReceiver.hs#L23) and leaves them, and the
open `import MicroHttp.Network.Socket`, unqualified. RFC-0031's sweep was scoped to
`test/{unit,integration}` and the benches post-date it. Cheap to fix while the lines are open,
and Correctness 3 has the same two files open anyway. `Stream.hs:34`'s unqualified
`import MicroHttp.Iteratee (strictEnumerator)` is untouched by the diff and exists for the
re-export; note only.

### Standards 2: a public constant exported for the tests

Judgement call. `compareBlockBytes` is exported from `Stream`
([Stream.hs:23](../../packages/micro-http/src/MicroHttp/Stream.hs#L23)) with no non-test
caller, which `agent-design-and-test-guidance.md` names as an anti-pattern. The RFC records
the reason (placing a difference on a block edge). The alternative is tests that write files
larger than any plausible block size, which is what the boundary tests need anyway. Either is
defensible; the export should at least be a conscious choice.

### Standards 3: duplicated test helper

Judgement call. `headOfEach` is defined identically in
[IterateeSpec.hs:168](../../test/unit/MicroHttp/IterateeSpec.hs#L168) and inline in
[StreamSpec.hs:245](../../test/unit/MicroHttp/StreamSpec.hs#L245). Tolerable for two copies; a
third should move it to `TestSupport`.

### Standards 4: compliant items

Per-function Haddock is present on every new top-level definition and both instances. The
`lift` re-export mirrors the existing `liftIO` convention. The `liftIO` widening is a strict
generalisation. Test names follow given/when/then. The ADR and RFC indexes regenerate with no
further diff. `markdownlint-cli2` passes on the four changed Markdown files.

## Summary

Correctness: six items, the worst being an outer acquire failure that becomes a verdict in
`filesEqual` (Correctness 1), with the inner-resource leak on outer failure (Correctness 2)
close behind and coupled to it. Spec: six items, the worst being the two goal claims those
same defects break. Standards: four items, none new, the worst being the unqualified imports
in the two bench files the diff already touches.

## Remediation Summary

Applied 2026-09-14, in the same working tree and still uncommitted. Test-first throughout: the
three new `IterateeSpec` cases and the new `StreamSpec` case were written before the fixes, and
the run confirmed three failures and one pass (the outer-release case, as Correctness 4
predicted) before any source change.

### Remediation of the correctness findings

- **Correctness 1, fixed.** `feedAcquireError` in `resourceEnumerator` now drives effect steps
  to the consumer's next input before delivering the failed end. New `IterateeSpec` case: an
  outer acquire failure under `runNested2` is the outcome and the inner resource is released.
  New `StreamSpec` case: a same-size second file made unreadable with `chmod 000` yields
  `Left (StreamSourceError "cannot open file: ...")`, the message the old loop produced.
- **Correctness 2, fixed by the first option.** A new class `MonadRelease` in
  `MicroHttp.Iteratee` carries `releaseOnFailure :: IO () -> m a -> m a`. The `IO` instance is
  `Exception.onException`; the `IterT` instance is `onFailure`, which is itself generalised
  from `Iter e a` to `MonadRelease m => IterT e m a`. `resourceEnumerator` guards every effect
  step it runs in its base layer with it, so an outer failure releases the inner resource
  before it short-circuits. `resourceEnumerator`, `fileEnumerator` and `fileEnumeratorChunked`
  now constrain `MonadRelease m` instead of `MonadIO m`; every existing caller infers `IO`.
  New `IterateeSpec` case: counted inner resource, failing outer stream, one release. A side
  effect worth naming: at the base layer an exception thrown by an effect step now releases
  the resource too, which the RFC-0042 review had recorded as a gap.
- **Correctness 3, fixed.** `EgressSender.hs` and `SocketReceiver.hs` match the pair
  `accept` returns. All three bench programs compile with the scripts' own `mhs` line against
  the installed package (MEASURED). The GHC sender then turned out not to build either: the
  Hackage index had never been fetched, and once it was, the `network` package's hsc2hs link
  hit the same Command Line Tools linker mismatch the Makefile already works around for GHC.
  A new `test/bench/build-sender.sh` writes that override into a gitignored
  `cabal.project.local`, keeps the build log instead of silencing it, and is what the three
  scripts now call. All three bench scripts ran end to end (MEASURED); the iteratee numbers
  from the real sender are in the RFC.
- **Correctness 4, test added.** Counted outer resource, inner consumer failing after reading
  both streams, one release.
- **Correctness 5 and 6.** No change needed.

### Remediation of the spec findings

- **Spec 1 and 2.** Covered by the fixes above; the `runNested2` Haddock now states the
  interleaving and the release guarantee accurately.
- **Spec 3.** A pointer paragraph at the top of the Proposal maps the spike's names to the
  implemented ones and corrects the `Zip` synonym's reading of the first parameter.
- **Spec 4.** The Phase 1 and Phase 2 checklist items that deviated carry dated Done notes;
  the `onFailure` item is now true as written, with the history recorded.
- **Spec 5.** The Findings paragraph says which bench programs were repaired when, and that the
  committed `make bench-iteratee` did not produce the recorded numbers. A "Review remediation
  (2026-09-14)" section in the RFC records the two defects and their fixes.
- **Spec 6.** No change needed.

### Remediation of the standards findings

- **Standards 1, fixed.** All three bench programs import with qualified aliases, and the
  `Stream` module's one unqualified import is gone: `strictEnumerator` is re-exported as
  `Iteratee.strictEnumerator` from the qualified import that was already there.
- **Standards 2, kept, deliberately.** `compareBlockBytes` stays exported. The two tests that
  use it place a difference exactly on a block edge, which is the case that catches an
  alignment bug; a test-local copy of the number would re-couple the tests to the constant
  without the compiler noticing when it drifts.
- **Standards 3, fixed.** `headOfEach` lives once in `TestSupport.Iteratee`, polymorphic in the
  error type; `IterateeSpec` pins it to its own error type in a one-line alias.

### Verification after remediation

MEASURED: `make format` produced no further diff, `make lint` passes, the unit suite is 520
examples and 0 failures under MicroHs and under GHC, and all three bench programs compile.
The full `make check` result is recorded below.

`make check` on the remediated tree: exit 0. Unit 520 examples and integration 130 under each
compiler, both smokes and the chrome gates green, no stale index or format diff.
