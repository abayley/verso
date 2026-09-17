# RFC-0050 code review: one consumer idiom in the streaming core

Status: review (2026-09-17). Change set: `a15775a..3aa50e7` on `main`, three commits (a Draft RFC, the
phase 1 measurement, phases 2 to 4). `MicroHttp.Iteratee` gained `foldChunksI`, the consumer loop
written once; `byteSinkI`, `MicroHttp.Stream.foldBlocksI` and `foldLinesI` are now that fold plus a
step; `readBodyStrict` and `fileSinkI` were deliberately left alone. A `cappedI` combinator was
written, measured at about twice the loop it wraps, and removed from the library. `make bench-consumer`
and `test/bench/ConsumerBench.hs` are new.

The review ran along the two usual independent axes, each in its own sub-agent: Spec (does the code do
what RFC-0050 says, and is the RFC accurate, including whether its mid-implementation amendments were
honest) and Standards (documented conventions and the Fowler smell baseline). A third sub-agent traced
correctness, concentrating on behavioural equivalence of the three re-expressed consumers and on the
bench's methodology. The sections are not reranked. Each finding is labelled MEASURED, VERIFIED or
INFERRED.

Baseline for the review, all MEASURED at `3aa50e7`: `make check` passes in full (mhs unit 657,
integration 166, the same under GHC, the editor checks, both smokes, the chrome gates, `bench-build`).

## RFC-0050 Correctness Findings

### Correctness 1: the three re-expressed consumers are exactly equivalent

VERIFIED against `git show 22a9cf3^` and `3aa50e7^`, path by path: an empty `Chunk`, a non-empty
`Chunk`, `EndOfStream Nothing`, `EndOfStream (Just err)`, and a failing step. All four terminal
residues match. `foldBlocksI` and `foldLinesI` have total steps, so the fold's `Left` path is
unreachable for them. The `Right`/`case` pair is one extra WHNF-only allocation per chunk.

### Correctness 2: the line fold's newline guard is safe, and for a stated reason

The old `foldLinesI` guarded `BS.null line` before `dropNewline`, which does `BS.last`/`BS.init` and
would crash on an empty chunk. VERIFIED safe on two independent grounds: `foldChunksI` skips empty
chunks before the step, and this is stated in its Haddock rather than incidental; and `linesI` cannot
emit an empty chunk anyway, since `feedLines` feeds `BS.snoc line 10`, so a blank line arrives as
`"\n"`. A blank line was therefore folded as `dropNewline "\n" == ""` before and after --
`Prelude.lines` semantics preserved.

### Correctness 3: `Done acc s` and `Done acc (EndOfStream Nothing)` are the same value

VERIFIED: in the old branch, `s` was bound by the pattern `EndOfStream Nothing` in that very branch.
Likewise for the failure branch. This settles the RFC's third open question.

### Correctness 4: the bench's baseline was not a fair copy

MEASURED, and the most consequential finding of the review. `handSink`, the bench's copy of the
pre-change `byteSinkI`, was monomorphic `Iter e ()` and called its writer directly, while the library
consumer it stood in for is `MonadIO m => IterT e m ()` and wraps the writer in `liftIO`. The row
therefore charged the fold for a dictionary the old consumer already paid, and the reported 1.17x was
an upper bound on a cost that is in fact not measurable. See the remediation below.

## RFC-0050 Spec Findings

### Spec 1: a Goal described a world the implementation does not produce

VERIFIED. When `cappedI` was dropped, the cap Goal was amended to "the byte cap written the same way in
the consumers that have one, in their step". Phases 3 and 4 then declined to touch either capped
consumer, so neither writes its cap in a step; both still check it inline in their own `consume`. The
Goal was amended to fit a plan that then changed again, and not amended a second time.

### Spec 2: phase 3's cost figure does not reproduce

MEASURED. The RFC claimed folding `readBodyStrict` was "a third to two fifths slower". Re-measured, the
gap is anywhere from 2% to 40% run to run, because those rows are dominated by the final
`BS.concat`, which is O(total x pieces). The hedge the RFC carried ("a direction, not a precise
figure") does not cover a spread that wide. The residue reason carries phase 3 on its own.

### Spec 3: a stale Security Impact sentence

VERIFIED. It promised "phase 3 includes a test that an over-cap stream still writes at most `limit`
bytes and leaves no partial file". Phase 3 was declined, so no test was added; the existing `StreamSpec`
cover applies to unchanged code, which is a sound gate but not what the sentence said.

### Spec 4: no scope creep

VERIFIED. One exported function, not a combinator library; `cappedI` lives only in the bench. The
Non-Goals naming `mapChunksI`, the slice rule and the enumerators are all honoured -- those files are
untouched. The declined phases' two stated reasons were checked independently against the source and
both hold: the differing over-cap residue (`Iteratee.hs`, `Stream.hs`, propagated at
`Middleware.hs:93,127`), and `fileSinkI` acting on all three terminal paths where `Done` gives no hook.

## RFC-0050 Standards Findings

### Standards 1: `foldChunksI`'s Haddock was stale and circular

MEASURED. It defined the fold's failure residue as "the residue `byteSinkI` leaves", but `byteSinkI` is
now defined *as* `foldChunksI`, so the contract pointed at its own caller. It also said five consumers
write the loop by hand (false after phases 2 to 4) and carried RFC-0050's question as still open. The
caller-facing fact -- that a failing step yields an **empty** residue -- is exactly the property the
declined phases turn on, and was not stated literally.

### Standards 2: `docs/architecture/streaming-algebra.md` was not updated

MEASURED: untouched in the range. That page documents this machinery, its "Streaming API Gaps" section
records combinators considered and closed, and its rule about a dictionary per chunk is cited three
times by the RFC. Both `foldChunksI` and the rejected `cappedI` measurement belonged there -- the
latter being the strongest empirical support that rule has.

### Standards 3: a Makefile comment was orphaned

MEASURED. `bench-consumer` was inserted between `bench-build`'s explanatory comment and `bench-build`
itself, so the comment ending "Run this after changing a framework signature the benches use" read as
documentation for the wrong target.

### Standards 4: judgement calls

`foldChunksI` had no direct spec, being covered only through three callers. `handSink` had no Haddock
of its own. `bench-consumer` took a `$(MICROHTTP_PKG)` prerequisite its neighbours lacked -- the
reviewer's reading, which this review accepts, is that the prerequisite is correct and the neighbours
were wrong. Two answered Open Questions were left unstruck.

## Summary

Correctness: no defects in the shipped code; one methodology defect in the bench that overstated the
cost of the change under review. Spec: one Goal describing an unimplemented world, one unreproducible
figure, one stale sentence; no creep, and the declined phases are substantiated. Standards: three hard
findings (stale Haddock, an un-updated architecture page, an orphaned comment) and four judgement
calls.

The worst finding on each axis is, respectively, the unfair bench baseline, the unreproducible
performance claim, and the circular Haddock. All three are claims this work made about itself rather
than defects in what it built, which is its own kind of signal.

## Remediation Summary

### Remediation of the correctness finding

`handSink` is now a verbatim copy of the pre-change `byteSinkI`, `MonadIO` constraint and `liftIO`
included, with a Haddock saying why both matter. Re-measured across three whole runs: the fold is
**1.00-1.10x** the hand-written loop, which does not separate from the noise; the wrapper is
**2.00-2.21x**; the inline cap **1.05-1.18x**. The RFC's table now reports ranges rather than one
run's best, and carries an explicit correction of its first version.

### Remediation of the spec findings

The cap Goal is struck and replaced with what happened: the cap stays written once per consumer, in
the loop each already has. Phase 3's cost paragraph now says the figure is not reliably measurable,
that repeat runs span 2% to 40%, and that the residue rule decides the phase on its own. The Security
Impact sentence says the caps are preserved by not touching either capped consumer. Both answered Open
Questions are struck, and the section ends "Nothing is open."

### Remediation of the standards findings

`foldChunksI`'s Haddock is rewritten: the step never sees an empty chunk, a failing step yields an
empty residue, and the two consumers that cannot use the fold are named with their reasons.
`streaming-algebra.md` gains a "Closed 2026-09-17" entry for `foldChunksI` and a paragraph recording
the `cappedI` measurement against its own dictionary-per-chunk rule, including the complement that
sharing a loop is not what costs -- a combinator a chunk *passes through* is. The Makefile comment and
target are reunited, the phase tag is dropped, and the `$(MICROHTTP_PKG)` prerequisite is added to the
six bench targets that lacked it.

`foldChunksI` gains a direct spec in `IterateeSpec` (five cases: chunks folded in order, an empty chunk
not reaching the step, a failing step's error and empty residue, a failed end propagating with the end
as residue, and no chunks at all). `handSink` gains its Haddock.

### Findings left as they are

None.

### Verification after remediation

MEASURED at the remediation commit: `make check` passes in full (mhs unit 662, integration 166, the
same under GHC, the editor checks, both smokes, the chrome gates, `bench-build`). `make bench-consumer`
runs and reproduces the corrected ratios.
