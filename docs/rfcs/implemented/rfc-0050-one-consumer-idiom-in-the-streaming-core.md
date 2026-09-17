---
id: RFC-0050
name: One Consumer Idiom In The Streaming Core
status: Implemented
owners:
    - alistair
created: 2026-09-17
updated: 2026-09-17
supersedes: []
superseded_by: null
related_rfcs:
    - RFC-0004
    - RFC-0041
    - RFC-0042
design_contract_rfcs:
    - RFC-0040
    - RFC-0043
---

# One Consumer Idiom In The Streaming Core

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-17 |
| Started   | 2026-09-17 |
| Completed | 2026-09-17 |

## Summary

Five consumers in the streaming core hand-write the same `NeedInput` / `Chunk` / `EndOfStream` loop,
and two of them also hand-write the same byte cap. Express the loop once as an effectful fold, and the
cap once as a wrapper, and define the five in terms of them -- **if** a benchmark shows the extra
combinator layer does not cost more than the duplication is worth. Under MicroHs each combinator is a
dictionary and an allocation per chunk, so this RFC is written to be abandonable at its measurement
gate, and phase 1 exists to decide that before any consumer is rewritten.

**Outcome.** The fold costs nothing measurable and landed for the three consumers that fit it. The cap
as a wrapper doubles the per-chunk cost and was dropped. The two consumers with a cap keep their own loops:
they refuse a chunk before accepting it, which gives a different failure residue, and one of them must
also act on every terminal path to close and remove its file.

## Context

The architecture review of 2026-09-16 (`docs/reviews/architecture-review-haskell-20260916.html`,
candidate 5, *Worth exploring*) had two halves. The second, one percent-decoder shared by `Form` and
`Http`, is done: `MicroHttp.Percent`, ADR-0095. This RFC is the first half.

Five consumers repeat one loop shape:

| consumer          | module            | step            | can the step fail? | cap | resource        |
| ----------------- | ----------------- | --------------- | ------------------ | --- | --------------- |
| `byteSinkI`       | `Iteratee.hs:432` | `IO (Either e)` | yes                | no  | no              |
| `readBodyStrict`  | `Iteratee.hs:356` | pure accumulate | no                 | yes | no              |
| `foldBlocksI`     | `Stream.hs:155`   | `IO a`          | no                 | no  | no              |
| `foldLinesI`      | `Stream.hs:202`   | `IO a`          | no                 | no  | no              |
| `fileSinkI`       | `Stream.hs:361`   | `IO` write      | no                 | yes | handle + unlink |

Each spells out the same three cases: a `Chunk`, skipped when empty; an orderly `EndOfStream`, which
resolves the consumer; and a failed `EndOfStream`, which becomes an `IterFailed` carrying the stream
state back. The review's framing is that `Stream` and `Iteratee` are "split by error type rather than
concept": `Iteratee` is polymorphic in the error, `Stream` fixes `StreamError`, so `Stream` re-writes
consumers its own core could express rather than instantiating them.

The shapes the review proposed:

```haskell
foldChunksI :: (s -> BS.ByteString -> m (Either e s)) -> s -> IterT e m s
cappedI     :: Int -> e -> IterT e m a -> IterT e m a
```

with `fileSinkI = cappedI limit err (foldChunksI write handle)` as the worked example, and
"delete: ... ~40 lines of loops".

### Why this is not obviously worth doing

`docs/architecture/streaming-algebra.md:203` states the tree's own rule, and it points the other way:

> Each combinator is a dictionary and an allocation per chunk under MicroHs, and the tree's rule is
> that a pipeline is written from one source, one sink, and the fewest transformers that make it
> correct.

`cappedI (foldChunksI step s)` is two combinators and a closure per chunk where there is now one
hand-written loop that branches inline. RFC-0041 already had to measure the cost of a single
dictionary on this path. Every byte of every request body and every file read passes through these
consumers, so a per-chunk regression here is not the few microseconds per request that ADR-0095's
`String` wrapper costs; it is proportional to payload.

That is why this RFC leads with the benchmark rather than ending with it. A result that says the
abstraction costs more than the duplication is a successful outcome of phase 1, not a failure of the
RFC, and the honest response is to close it and record the number.

### What the duplication actually costs today

Small, and worth stating plainly so the benefit is not overstated. `foldBlocksI` and `foldLinesI` have
**no callers outside `Stream.hs`** (measured), so three of the five are internal. The loops are short
and each has been individually correct for some time. The real argument is not line count but that the
cap exists twice with subtly different failure behaviour, and that a sixth consumer will be written by
copying a fifth.

### The differences a shared fold must preserve

These are observable and tested, and they are where a careless unification would break something:

- **Failure residue.** `byteSinkI` fails with `Chunk BS.empty`; `readBodyStrict` and `fileSinkI` fail
  the over-cap case with `Chunk bytes`, the chunk that overflowed, unconsumed; the `EndOfStream (Just
  err)` case carries the end back. `IterFailed` carries that residue and specs assert it.
- **Cap semantics.** Both capped consumers check *before* writing or accumulating, so an over-cap
  stream has written at most `limit` bytes. `fileSinkI` additionally removes the partial file.
- **Resource lifetime.** `fileSinkI` opens on first demand and closes on *every* exit path, removing
  the partial file on failure. The review's `cappedI limit err (foldChunksI write h)` sketch assumes a
  handle that already exists and says nothing about the bracket; `Iteratee` has
  `releaseOnFailure` (`Iteratee.hs:124`) for this, and a shared fold must not lose it.
- **`foldLinesI`** drops a trailing newline before the step sees the line.

## Goals

- One implementation of the `NeedInput` / `Chunk` / `EndOfStream` loop in `MicroHttp.Iteratee`.
- ~~One implementation of the byte cap.~~ Dropped after phase 1 measured a shared cap combinator at
  about twice the loop it wraps, and phases 3 and 4 found that the two consumers with a cap cannot use
  the fold at all. The cap stays written once per consumer, in the loop each already has.
- The five consumers keep their exact observable behaviour, residues included.
- A recorded before-and-after measurement, whatever it says.

## Non-Goals

- Merging `MicroHttp.Stream` into `MicroHttp.Iteratee`, or changing how `StreamError` relates to the
  polymorphic error. Only the consumers move.
- A general combinator library. `streaming-algebra.md` rejects a large surface, and this RFC adds two
  functions, not a catalogue.
- Changing any enumerator, the slice rule, or `mapChunksI`.
- Percent-decoding, done in ADR-0095.

## Proposal

Add one function to `MicroHttp.Iteratee`:

```haskell
foldChunksI :: (Monad m) => (s -> BS.ByteString -> m (Either e s)) -> s -> IterT e m s
```

It is the loop: empty chunks skipped, orderly end resolves with the accumulator, failed end propagates,
and a step returning `Left` fails with that error.

**There is no `cappedI`.** The wrapper this RFC originally proposed was written and measured in phase 1
and costs 2.40x per chunk, more than the loop it wraps. A consumer that needs a cap carries the running
count in its own accumulator and returns `Left` when the next chunk would exceed it, which is 1.26x and
keeps the check where the current consumers already have it: before the write. The cap is still written
once per consumer, but it is four lines inside a step rather than a second consumer in the path.

Then:

- `byteSinkI` = `foldChunksI` over `()` with the writer's `Either`. (Done in phase 1.)
- `foldBlocksI`, `foldLinesI` = `foldChunksI` with the step lifted into `Right`, `foldLinesI` dropping
  the newline in its step.
- `readBodyStrict` = `foldChunksI` over the chunks seen and their total, capped in the step.
- `fileSinkI` = the handle bracket, then `foldChunksI` over the count, capped in the step, with the
  existing release path.

## Alternatives Considered

- **Share only the cap.** Proposed here as the safe retreat if the fold proved expensive, and
  **measured in phase 1 as the worst option of the three**: as a wrapper the cap costs 2.40x per chunk
  against the fold's 1.17x. Recorded because the reasoning that made it look safe -- that the cap is
  where the correctness risk is -- was sound, and only the measurement overturned it.
- **Share nothing; add a test that the five agree.** The tactic ADR-0094 chose for the two HTML
  escapers. It does not fit here: the five deliberately differ, so there is no single behaviour to pin.
- **A typeclass over consumer shapes.** Rejected on the same grounds as the free monad in
  `streaming-algebra.md:178`: a dictionary per chunk is the cost being avoided.
- **Delete `foldBlocksI` / `foldLinesI`.** They have no external callers, so a fourth option is to
  inline them at their `Stream.hs` use sites and unify only the three that remain. Worth revisiting if
  phase 1 is marginal.

## Security Impact

None. The caps are the security-relevant behaviour, and this RFC preserves them exactly -- in the end
by not touching either capped consumer at all, so the existing cover in `StreamSpec` (an over-cap body
fails and leaves no partial file) still applies unchanged to unchanged code.

## Reliability Impact

The risk is concentrated in `fileSinkI`, the only consumer holding a resource: a unification that drops
a release path leaks a handle or leaves a partial file on an error path that no test exercises. Phase 4
is therefore ordered last and gated on the existing removal tests, and the RFC is explicit that the
review's sketch omits the bracket.

Against that, the cap existing twice is itself a reliability risk today: a fix to one is not a fix to
the other.

## Compatibility Impact

None intended outside the framework. `foldBlocksI` and `foldLinesI` have no callers outside
`Stream.hs`; `byteSinkI`, `readBodyStrict` and `fileSinkI` keep their signatures, so the wiki
application is untouched. If a signature has to change to make a consumer expressible, that is a signal
the shared shape is wrong, and the RFC says so rather than changing the caller.

## Testing and Quality Gates

The existing suites are the gate -- `StreamSpec`, `IterateeSpec` and `FormSpec` already cover these
consumers, which is what the review meant by "test with the existing StreamSpec". Behaviour to verify,
one bullet per operator-visible scenario:

- A body over the cap fails with the supplied error, having written at most `limit` bytes.
- An over-cap file sink leaves no partial file behind.
- A transport failure mid-body reaches the sink as a failed end, so a routed part releases what it
  holds (`FormSpec` asserts this today).
- A failed consumer's residue is unchanged, per consumer.
- A line fold still reproduces `Prelude.lines` semantics, trailing newline included.
- `make check` green, including `bench-build`.

## Rollout Plan

Phases are ordered so the cheapest consumers prove the shape before the one holding a resource, and so
the measurement comes first.

### Phase 1: measure, and decide

- [x] Record a baseline. **The plan changed on contact with the code**, twice, and both corrections
      matter more than the original plan did.
      `make bench-iteratee` does not drive any of the five consumers -- it uses a `countingSink`
      defined in the bench, and its own comment says `readBodyStrict` is "deliberately not benched
      here at this volume". Worse, it and `bench-egress` saturate a socket, where syscalls dominate
      and would hide a per-chunk regression rather than expose it: the baseline this RFC proposed
      would have been falsely permissive about exactly the cost being judged.
      So the measurement is a new in-process bench, `make bench-consumer`
      (`test/bench/ConsumerBench.hs`), which feeds chunks already in memory and times the loop alone.
      And the consumer re-expressed first is `byteSinkI`, not `foldBlocksI`: `foldBlocksI` is not
      exported (it has no callers outside `Stream.hs`), so it cannot be driven from a bench, while
      `byteSinkI` is exported and its failable step exercises `foldChunksI`'s full signature.
- [x] Write `foldChunksI` and `cappedI`, and re-express `byteSinkI`.
- [x] Re-measure.

#### What it measured

Nanoseconds per chunk, best of 9, 8 MB per run at each of the three chunk sizes for the sink rows;
64 bytes exaggerates per-chunk cost on purpose, 4096 is the decoder slice, 16384 a socket read. The
writer only bumps a counter, so these are the loop's own cost, not the sink's work. Ranges are across
three whole runs, because at these margins one run's best is not a number to quote alone.

| variant                         | vs hand-written |
| ------------------------------- | --------------: |
| hand-written loop (before)      |            1.00 |
| `foldChunksI`                   |   **1.00-1.10** |
| `cappedI` wrapped around it     |   **2.00-2.21** |
| the same cap inline in the fold |   **1.05-1.18** |

The wrapper's ratio holds at all three chunk sizes, so it is per-chunk overhead and not a throughput
artefact. The fold's does not separate from the noise at any of them.

**Sharing the loop costs nothing measurable; sharing the cap as a wrapper doubles the per-chunk cost.**
`cappedI` adds about 1.2 microseconds per chunk, roughly the whole cost of the loop it wraps, because a
chunk passes through a second consumer: the wrapper's own `NeedInput`, then a `feedChunk` into the
inner one. That is precisely the "dictionary and an allocation per chunk" that
`streaming-algebra.md:203` warns about, arriving exactly where the warning said it would. The fourth
row is the constructive part: the same cap checked inside a fold's step, with the running count in the
accumulator, is back down in the noise.

**A correction to this table's first version.** It reported the fold at 1.17x. That figure was an
artefact of the bench, not of the fold: the hand-written row was a monomorphic copy, while the library
consumer it was compared against is `MonadIO m => IterT e m ()` and wraps its writer in `liftIO`, so
the row charged the fold for a dictionary the old consumer already paid. With the copy made faithful,
down to the constraint, the difference disappears. The error only ever made the fold look worse than
it is, so the gate decision stands, but the number was wrong and is corrected here rather than
quietly.

**This inverts the fallback this RFC proposed.** "Share only the cap" was written as the safe retreat
if the fold proved costly. It is the worst of the options measured: the fold is the cheap half.

#### Also found

`readBodyStrict` **exhausts the MicroHs evaluator stack** on 131072 chunks of 64 bytes (8 MB),
`ERR: stack overflow`, before any of this change. It accumulates a list of every chunk and
concatenates once at the end, and its own Haddock warns that concat is O(total x pieces). The bench
gives it 1 MB so it survives. This is a pre-existing limit, not a regression, but phase 3 plans to
re-express this consumer and must not make it worse; its per-chunk numbers are dominated by that final
concat, so it is useless as a probe for loop cost.

- [x] **Gate: proceed.** ~1.17x on a loop costing about a microsecond is roughly 0.18 microseconds per
      chunk, about 12 microseconds per megabyte at socket-sized chunks, against consumers that also
      write a file or a socket. `cappedI` is dropped rather than kept unused; its measurement stays
      reproducible from a local copy in the bench, the way `PercentDecodeBench` keeps the escaper it
      replaced.

### Phase 2: the consumers with no cap and no resource

- [x] `foldBlocksI` and `foldLinesI` in terms of `foldChunksI` (`byteSinkI` landed in phase 1).
- [x] `StreamSpec` and `IterateeSpec` green with no test edits.

Each is now one line plus its step. `foldLinesI` resolved with `Done acc s` where the fold resolves
with `Done acc (EndOfStream Nothing)`; on the orderly path those are the same value, which settles the
third open question.

### Phase 3: the cap -- declined

`readBodyStrict` stays hand-written, for two independent reasons found on the code.

**Its failure residue is not the fold's.** Over the cap it fails with `Chunk bytes`, the chunk it
refused, because the check happens *before* the chunk is accepted. `foldChunksI` fails with
`Chunk BS.empty`, which is right for `byteSinkI`, where the step fails *after* attempting the write.
Both are correct for their consumer and they are not the same rule; `MicroHttp.Middleware` propagates
that residue (`Middleware.hs:93,127`), so it is not private. Making the fold carry either would mean a
parameter that exists for one caller.

**Its step is pure**, which is a second, weaker reason. It conses a chunk onto a list and nothing else,
so it is the one consumer with no `IterM` per chunk at all, and folding it adds one. The cost of that
is not reliably measurable here: these rows are dominated by the final `BS.concat`, which is
O(total x pieces), and repeat runs put the difference anywhere from 2% to 40%. It is a reason to
prefer leaving the consumer alone, not a number to quote. **The residue rule above is what decides
this phase**, and it decides it on its own.

### Phase 4: the file sink -- declined

`fileSinkI` stays hand-written, for the residue reason above and one more: it is the only consumer that
must act on **every** terminal path. It closes the handle on an orderly end, and closes and removes the
partial file both when the cap is exceeded and when the stream fails (`Stream.hs`, `abandon`).
`foldChunksI` resolves with `Done acc` and offers no hook for the orderly close, so expressing this
consumer needs a fold that takes a finaliser -- which is a bracket, and the module already has
`onFailure` and `resourceEnumerator` for that. Adding a third mechanism for one caller is the
generality this RFC's non-goals rule out.

This is the answer to the second open question: the bracket stays outside, because the consumer that
has one does not go through the fold.

### Phase 5: close

- [x] Re-measure and record the final numbers against the phase 1 baseline (above; `make
      bench-consumer` is now a standing target).
- [x] `make check`.
- [x] Code review over the range (Standards, Spec, Correctness), remediated:
      `docs/reviews/rfc-0050-code-review-20260917.md`. Its sharpest findings were about this RFC's own
      claims rather than the code -- an unfair bench baseline that overstated the fold's cost, and a
      phase 3 figure that did not reproduce -- and both are corrected above.

#### Where this landed

Three of the five consumers go through `foldChunksI`: `byteSinkI`, `foldBlocksI`, `foldLinesI` -- the
three with no cap and no resource. The two that have one keep their own loops, and the reasons are
recorded above rather than left for the next reader to rediscover. The review's "delete ~40 lines of
loops" is about half met.

That is a smaller result than the RFC set out to get, and it is the right one: the five consumers were
never five copies of one thing. Three are the same loop and now say so once. The other two differ in
where they refuse a chunk and in what they must do when the stream ends, which is exactly the part a
shared loop cannot hold.

## Open Questions

- ~~Should `cappedI` count the bytes it passes on, or take a projection from the accumulator?~~
  Settled by phase 1: there is no `cappedI`, and the count lives in the consumer's accumulator.
- ~~Does `fileSinkI`'s bracket belong inside `foldChunksI`, or stay outside?~~ Settled by phase 4:
  outside, because the consumer that has one does not go through the fold.
- ~~`foldLinesI` resolves with `Done acc s` where `foldBlocksI` uses `Done acc (EndOfStream Nothing)`.~~
  Settled by phase 2: in that branch `s` is bound by the pattern `EndOfStream Nothing`, so they are the
  same value.

Nothing is open.
