---
id: RFC-0050
name: One Consumer Idiom In The Streaming Core
status: In Progress
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
| Completed |            |

## Summary

Five consumers in the streaming core hand-write the same `NeedInput` / `Chunk` / `EndOfStream` loop,
and two of them also hand-write the same byte cap. Express the loop once as an effectful fold, and the
cap once as a wrapper, and define the five in terms of them -- **if** a benchmark shows the extra
combinator layer does not cost more than the duplication is worth. Under MicroHs each combinator is a
dictionary and an allocation per chunk, so this RFC is written to be abandonable at its measurement
gate, and phase 1 exists to decide that before any consumer is rewritten.

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
- One implementation of the byte cap, reusable by `Form`'s `tooLarge` and by upload sinks.
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

Add to `MicroHttp.Iteratee`:

```haskell
foldChunksI :: (Monad m) => (s -> BS.ByteString -> m (Either e s)) -> s -> IterT e m s
cappedI     :: Int -> e -> (s -> Int) -> IterT e m s -> IterT e m s
```

`foldChunksI` is the loop: empty chunks skipped, orderly end resolves with the accumulator, failed end
propagates, and a step returning `Left` fails with that error. `cappedI` counts bytes as they pass and
fails before handing on the chunk that would exceed the limit, leaving the residue the current
consumers leave.

Then:

- `byteSinkI` = `foldChunksI` over `()` with the writer's `Either`.
- `foldBlocksI`, `foldLinesI` = `foldChunksI` with the step lifted into `Right`, `foldLinesI` dropping
  the newline in its step.
- `readBodyStrict` = `cappedI` over `foldChunksI` accumulating chunks, then concatenated.
- `fileSinkI` = the handle bracket, then `cappedI` over `foldChunksI`, with the existing release path.

**The decision is at the end of phase 1, not here.** If the benchmark shows a per-chunk regression that
matters, phases 2 onward do not happen; the RFC is closed as Rejected with the measurement in it, and
`streaming-algebra.md` gains the number so the next reader does not re-propose this.

## Alternatives Considered

- **Share only the cap.** `cappedI` alone removes the duplicated, subtly divergent limit logic -- the
  part with real correctness risk -- and leaves the loops alone, so it adds one combinator layer to two
  consumers rather than to five. If phase 1 says the fold is too expensive but the cap is not, this is
  the fallback, and it collects most of the value.
- **Share nothing; add a test that the five agree.** The tactic ADR-0094 chose for the two HTML
  escapers. It does not fit here: the five deliberately differ, so there is no single behaviour to pin.
- **A typeclass over consumer shapes.** Rejected on the same grounds as the free monad in
  `streaming-algebra.md:178`: a dictionary per chunk is the cost being avoided.
- **Delete `foldBlocksI` / `foldLinesI`.** They have no external callers, so a fourth option is to
  inline them at their `Stream.hs` use sites and unify only the three that remain. Worth revisiting if
  phase 1 is marginal.

## Security Impact

None. The caps are the security-relevant behaviour, and this RFC preserves them exactly; phase 3
includes a test that an over-cap stream still writes at most `limit` bytes and leaves no partial file.

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

Nanoseconds per chunk, best of 9, 8 MB per run at each chunk size; 64 bytes exaggerates per-chunk cost
on purpose, 4096 is the decoder slice, 16384 a socket read. The writer only bumps a counter, so these
are the loop's own cost, not the sink's work.

| variant                         |    64 B |  4096 B | 16384 B | vs hand-written |
| ------------------------------- | ------: | ------: | ------: | --------------: |
| hand-written loop (before)      | 1135.94 | 1030.76 | 1003.91 |            1.00 |
| `foldChunksI`                   | 1323.19 | 1194.34 | 1187.50 |       **~1.17** |
| `cappedI` wrapped around it     | 2659.10 | 2499.02 | 2396.48 |       **~2.40** |
| the same cap inline in the fold | 1441.35 | 1314.45 | 1255.86 |       **~1.26** |

The ratios hold across all three chunk sizes, so they are per-chunk overhead and not a throughput
artefact.

**The shared fold is cheap and the shared cap, as a wrapper, is not.** `foldChunksI` costs about 17%
of a loop whose whole cost is around a microsecond, so roughly 0.18 microseconds per chunk: at
socket-sized chunks that is about 12 microseconds per megabyte streamed, against a real consumer that
also writes to a file or a socket. `cappedI` costs 1.4 microseconds per chunk, more than the loop it
wraps, because a chunk passes through a second consumer: its own `NeedInput`, then `feedChunk` into
the inner one. That is precisely the "dictionary and an allocation per chunk" that
`streaming-algebra.md:203` warns about, arriving exactly where the warning said it would.

The fourth row is the constructive part: the same cap checked inside the fold, with the running count
carried in the accumulator instead of a wrapper, costs 1.26x rather than 2.40x. So the cap is cheap to
share; only its packaging as a combinator is expensive.

**This inverts the fallback this RFC proposed.** "Share only the cap" was written as the safe retreat
if the fold proved costly. It is the worst of the options measured: the fold is the cheap half.

#### Also found

`readBodyStrict` **exhausts the MicroHs evaluator stack** on 131072 chunks of 64 bytes (8 MB),
`ERR: stack overflow`, before any of this change. It accumulates a list of every chunk and
concatenates once at the end, and its own Haddock warns that concat is O(total x pieces). The bench
gives it 1 MB so it survives. This is a pre-existing limit, not a regression, but phase 3 plans to
re-express this consumer and must not make it worse; its per-chunk numbers are dominated by that final
concat, so it is useless as a probe for loop cost.

- [ ] **Gate.** Decide whether ~1.17x per chunk on the loop is worth one implementation of it.

### Phase 2: the consumers with no cap and no resource

- [ ] `foldLinesI`, then `byteSinkI`, in terms of `foldChunksI`.
- [ ] `StreamSpec` and `IterateeSpec` green with no test edits; a test that needs editing means
      behaviour changed, so investigate rather than edit.

### Phase 3: the cap

- [ ] `readBodyStrict` in terms of `cappedI` and `foldChunksI`, residue preserved.
- [ ] `FormSpec`'s cap cases green unedited.

### Phase 4: the file sink

- [ ] `fileSinkI` in terms of the same two, keeping the open-on-demand bracket and every release path.
- [ ] The partial-file removal cases green unedited.

### Phase 5: close

- [ ] Re-measure and record the final number against the phase 1 baseline.
- [ ] `make check`.
- [ ] Code review over the range (Standards, Spec, Correctness), remediate, then move this RFC to
      `docs/rfcs/implemented/` and run `bun run rfc:index`.

## Open Questions

- Should `cappedI` count the bytes it passes on, or take a `s -> Int` from the accumulator? The
  signature above takes the projection so the fold's own state stays the source of truth, but
  `byteSinkI`'s state is `()`, so a counting `cappedI` may be simpler. Phase 1 settles it on the code.
- Does `fileSinkI`'s bracket belong inside `foldChunksI` as an acquire parameter, or stay outside as it
  is now? Keeping it outside is assumed; phase 4 confirms or reopens.
- `foldLinesI` resolves with `Done acc s` where `foldBlocksI` uses `Done acc (EndOfStream Nothing)`.
  These are the same value on the orderly path, but the shared fold must pick one; confirm no spec
  distinguishes them.
