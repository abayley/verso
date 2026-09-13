---
id: RFC-0041
name: Multi-source iteratees
status: Implemented
owners:
    - Alistair Bayley
created: 2026-09-13
updated: 2026-09-13
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0040]
related_refs: []
---

# RFC-0041: Multi-source iteratees

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-09-13 14:00 NZST |
| Started   | 2026-09-13 21:30 NZST |
| Completed | 2026-09-13 23:30 NZST |

## Summary

The framework's iteratee core (RFC-0012, `MicroHttp.Iteratee`) drives one consumer from one producer, and
that consumer has a single input channel. That fits produce-transform-consume pipelines and sequential
fan-in (feed one sink from several sources in turn), but it cannot express a **lock-step combination of two
sources** -- read a block from each, compare or merge, decide whether to continue -- so the one place that
needs it, `Stream.filesEqual`, is hand-rolled over two raw handles instead of over the file readers. This RFC
proposes generalising the iteratee from its fixed `IO` base to a base-monad-parametric transformer
(`IterT e m a`), so a consumer can nest a second iteratee as its base monad and read both streams under its
own control -- Oleg Kiselyov's "several sources to one sink" (the 2enum1iter construction). A spike
(`spike/iteratee-multisource/Spike.hs`, on the `spike/iteratee-multisource` branch) proves the shape and
measures the cost. As authored the change was **not proposed for adoption**: it was recorded so that when a
second lock-step or merge consumer appeared the design and its cost were already understood. On 2026-09-13
the owner waived that gate (see "Decision to proceed") so that file I/O is consistently streamed through the
one bracket and the tree has a worked example of combining several streams into one consumer.

## Context

`MicroHttp.Iteratee.Iter e a` fixes two things that this RFC would make parametric:

```haskell
data Iter e a
    = Done a (Stream e)
    | NeedInput (Stream e -> Iter e a)
    | IterM (IO (Iter e a))            -- effect layer hardcoded to IO
    | IterFailed e (Stream e)

type Enumerator e a = Iter e a -> IO (Iter e a)   -- and here
```

The element is always a `ByteString` chunk (`Stream e = Chunk ByteString | EndOfStream (Maybe e)`) and the
effect layer is always `IO`. The model is **push**: an `Enumerator` (a producer) drives an `Iter` (a
consumer), feeding it chunks; the consumer is passive, saying `NeedInput` and waiting to be fed. It has one
input channel.

Three shapes of composition follow from that, and RFC-0040 leaned on the first two:

- **Transform (1 to 1)**, the enumeratee: an `Iter -> Iter` that rewrites the stream between a producer and a
  consumer (`takeN`, the escaping and counting stages in `Middleware`, the per-block escape in
  `Stream.transformedFileBody`).
- **Sequential fan-in (many to 1, in turn)**: feed one sink from several sources one after another. This
  works because `Enumerator e a = Iter e a -> IO (Iter e a)` returns the consumer still in its continuation
  state, so a second enumerator can carry on feeding it. RFC-0040's streamed diff does exactly this -- shell
  bytes, then the diff file's lines, then more shell bytes into one sink -- using `Iteratee.feedChunk`, which
  feeds one chunk **without** sending end-of-stream (the single real end-of-stream is delivered once, by
  `run`, at the end).
- **Lock-step combination (many to 1, in step)**: read from two sources at the same position and combine
  them -- compare (`filesEqual`), or merge (a sorted-shard merge). This does **not** fit, because a consumer
  has one input channel and cannot pull from two producers. `Stream.filesEqual` is therefore hand-rolled: it
  opens both files, loops `hGet` on each, compares block for block, and closes both -- reusing none of the
  file-reading machinery (`fileEnumeratorChunked`, the `resourceEnumerator` bracket).

This RFC arose from the RFC-0040 phase-9 review. Consolidating the file readers onto one bracket
(`fileEnumeratorChunked`) and recording ADR-0091 (network and file I/O is block-streaming by default) left
`filesEqual` as the visible exception, and the first framing of the exception -- "add a pull-style `Source`
as the dual of the push enumerator" -- was wrong: it would introduce a second streaming paradigm to absorb
one call site. Oleg Kiselyov's iteratee notes give the answer that stays inside the one paradigm.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, mark it complete in the phase checklist at
once, with a dated "Done" note recording anything that deviated from the plan.

## Goals

- Express a lock-step or k-way combination of streaming sources within the existing iteratee paradigm, with
  the consumer in control of how much it reads from each source.
- Reuse the enumerators for resource bracketing (open/read/close on every exit), so a multi-source consumer
  does not hand-roll raw handles.
- Keep the current push pipeline (produce-transform-consume, sequential fan-in) working unchanged, and
  recover today's monomorphic core as the `m = IO` instance (`type Iter e a = IterT e IO a`).
- Byte-for-byte identical behaviour where a consumer is rewritten onto it (`filesEqual`'s verdict is
  unchanged).

## Non-Goals

- A merge consumer. The sorted-shard merge that was the anticipated trigger is not built here; this RFC
  delivers the generalised core, the two-source driver and `filesEqual` on it, which is what a merge would
  reuse.
- A second (pull) streaming paradigm alongside the push enumerator.
- Changing the element type. Chunks stay `ByteString`; only the effect layer becomes a parameter.
- Any change to socket or HTTP behaviour. Those layers pin `m = IO` and are unaffected at runtime.

## Proposal

The shapes below are the spike's, kept as authored. The implementation renamed and reshaped them: `enumFile`
with `toBase` became `resourceEnumerator` and `fileEnumeratorChunked` under a `MonadRelease` (originally
`MonadIO`) base-monad constraint; `runZip2` became `runNested2`; `headMaybe` became `headChunk`; `equalZip`
became `equalBlocks`; and the first parameter of `IterT` is the failure type `e`, not the element type the
`Zip` synonym below suggests. See "Decision to proceed" and "Findings from implementation".

### The generalised iteratee

Make the effect layer a parameter:

```haskell
data IterT e m a
    = Done a (Stream e)
    | NeedInput (Stream e -> IterT e m a)
    | IterM (m (IterT e m a))          -- was IO; now any base monad m
    | IterFailed e (Stream e)

type Enumerator e m a = IterT e m a -> m (IterT e m a)
```

The current core is exactly the `IO` instance:

```haskell
type Iter e a = IterT e IO a
```

`Functor`/`Applicative`/`Monad`, `feedStream`, `run`, `readBodyStrict`, `byteSinkI`, `resourceEnumerator` and
the file/socket enumerators carry over unchanged except for threading `m` (and gaining a `Monad m` or
`Functor m` constraint). One genuinely new function is needed -- the monad-transformer `lift`, which is what
lets a consumer nest a second iteratee as its base monad:

```haskell
lift :: Functor m => m a -> IterT e m a
lift m = IterM (fmap (\a -> Done a (Chunk BS.empty)) m)
```

### Reading from two sources: nesting

The consumer's base monad is itself an iteratee over the second stream, so it has one input channel per
layer:

```haskell
type Zip a = IterT ByteString (IterT ByteString IO) a
--                  ^inner (A)          ^outer (B)   ^IO at the bottom

equalZip :: Zip Bool
equalZip = do
    blockA <- headMaybe          -- reads file A (the inner stream)
    blockB <- lift headMaybe     -- reads file B (the outer stream, the base monad)
    case (blockA, blockB) of
        (Nothing, Nothing)             -> pure True
        (Just a, Just b) | a == b      -> equalZip
        _                              -> pure False
```

`headMaybe` on the inner layer reads A; `lift headMaybe` reads B. The consumer decides, per step, how much to
take from each -- Oleg's example reads the fifth word of one file and the first matching line of another, the
amount from one depending on the other.

### Driving it

Two enumerators feed the two layers, one per file. A file enumerator becomes base-monad-generic, with the
raw `IO` reads lifted into whichever layer it feeds (`id` at the base, `lift` at an inner layer):

```haskell
enumFile :: Monad m => (forall x. IO x -> m x) -> Int -> FilePath -> IterT e m a -> m (IterT e m a)
```

Running a two-layer consumer peels the layers with two `run`s -- enumerate A at the inner layer, then
enumerate B at the base layer:

```haskell
filesEqualZip pathA pathB = do
    let overB = enumFile lift blockBytes pathA equalZip >>= run   -- inner layer (A) resolved
    outcome <- enumFile id  blockBytes pathB overB      >>= run   -- base layer (B) resolved
    pure (flatten outcome)                                        -- outcome :: Either e (Either e Bool)
```

Because each `run` returns `Either e a`, a k-layer consumer yields a k-deep nested `Either` the caller
flattens. To keep that off callers, the framework would provide arity-specific helpers -- `runZip2`,
`runZip3` -- that hide the multi-`run` dance and the nesting behind a plain signature.

### What moves onto it

`Stream.filesEqual` (and `TreeMove.assetConflicts`, which calls it) is rewritten as `equalZip` above: the
same block-at-a-time, stop-at-first-difference verdict, but over two `enumFile` brackets instead of two raw
handles. A future sorted-shard merge would be the same shape with `>` in place of `==` and an output sink.

### Migrating the core

Every `IterM (IO ...)` in `MicroHttp.Iteratee` becomes `IterM (m ...)`; `run`, `resourceEnumerator`,
`byteSinkI`, `takeN`, `feedChunk` and the enumerators in `MicroHttp.Stream` grow an `m` and a `Monad m`
constraint. The socket writer, the HTTP response writer, the middleware and every handler pin `m = IO` (via
`Iter e a = IterT e IO a`), so they are mechanical to update and unchanged at runtime. `enumFile`-style
producers grow the `forall x. IO x -> m x` argument.

## Alternatives Considered

- **Keep hand-rolling each multi-source consumer (status quo).** `filesEqual` is a dozen clear lines over two
  handles. For one call site this is the right cost. It stops being right when a second consumer (a k-way
  merge) would duplicate the raw-handle plumbing and its bracketing. Adopted for now; this RFC is the plan
  for when it stops.
- **A pull-style `Source` as the dual of the enumerator** (`newtype Source e = Source (IO (Maybe (ByteString,
  Source e)))`, zipped with `zipSources`). It works, but it introduces a second streaming paradigm alongside
  the push enumerator -- two source models and adapters between them -- for negative net simplicity. Rejected
  in favour of generalising the one model we have.
- **Element-polymorphic streams / a full library (conduit, pipes).** Generalising the chunk type as well as
  the base monad, or adopting a bidirectional library, would express zips and merges directly. It is far more
  than this project needs, pulls in a dependency or a large core, and is out of scope for a MicroHs target
  (RFC-0007 portability). Rejected.
- **Sequential fan-in only (`feedChunk`).** Feeding one sink from two sources in turn does not give lock-step
  comparison: the sink would see all of A then all of B and would have to buffer one whole file to compare,
  which defeats streaming. Sufficient for the diff (concatenation), insufficient for `filesEqual`.

## Security Impact

None. The change is at the type level (the effect layer becomes a parameter); it processes the same bytes the
same way. A consumer rewritten onto it (`filesEqual`) keeps its verdict, so no de-duplication or
conflict-detection decision changes.

## Reliability Impact

Neutral to positive. A nested-iteratee `filesEqual` drives each file through a proper `enumFile` bracket, so
both handles are closed on every exit path (early stop at first difference, mid-stream failure, completion) by
the same discipline the other readers use -- rather than by the hand-rolled loop's own `hClose` calls. No new
failure mode; the streamed-comparison race the current `filesEqual` documents (a concurrent write to either
file) is unchanged.

## Compatibility Impact

Internal only; no data, wire, or configuration change. `type Iter e a = IterT e IO a` keeps the name every
in-tree user already writes, so handler and middleware signatures are unchanged. The migration is a
mechanical `m`-threading across `MicroHttp.Iteratee` and `MicroHttp.Stream` plus pinning `m = IO` at the
socket/HTTP boundary; it lands in one change with the suites as the gate.

## Testing and Quality Gates

- `filesEqual` rewritten as a nested-iteratee zip agrees with a whole-file oracle on: identical small,
  one-byte difference, different length, both empty, identical multiblock, and a difference straddling a block
  boundary. (The spike already checks these six; they become unit tests when adopted.)
- The existing `Stream.filesEqual` tests and the `storeAsset`/`TreeMove.assetConflicts` de-duplication tests
  stay green -- the verdict is byte-identical.
- `make check` stays green under **both** MicroHs and GHC. The GHC half is not enough on its own here (see
  Open Questions): the generalisation uses `RankNTypes` and higher-kinded parametricity that must be
  confirmed to compile under MicroHs before adoption.

## Decision to proceed (2026-09-13)

The gate in the original Rollout Plan (a second lock-step consumer) was waived by the owner: the aim is that
every file read goes through the one enumerator bracket (ADR-0091), and that the tree carries a worked
example of a consumer combining several streams. Two of the open questions were settled before starting:

- **MicroHs feasibility.** The spike compiles and runs under mhs 0.16.5.0 unchanged (`RankNTypes`, the
  higher-kinded `IterT e m`, the nested `IterT e (IterT e IO)`), and passes its six oracle cases (MEASURED,
  2026-09-13). A probe also confirmed that `Control.Monad.IO.Class.MonadIO` and
  `Control.Monad.Trans.Class.MonadTrans` are available under mhs and that instances for a transformer build.
- **The rank-2 `toBase` argument is replaced by `MonadIO`.** A generic enumerator's raw reads are `IO`; the
  layer it feeds is any `MonadIO m`, and `IterT e m` is `MonadIO` whenever `m` is. So
  `resourceEnumerator :: MonadIO m => ... -> EnumeratorT e m a` needs no per-call lifting function: at the
  base layer `m = IO` and at an inner layer `m = Iter e`, both by inference. The existing
  `Iteratee.liftIO :: IO a -> Iter e a` becomes the class method at `m = Iter e`, so its callers are
  unchanged.
- **Generic in the core, pinned at the boundary.** `MicroHttp.Iteratee` and the enumerators in
  `MicroHttp.Stream` are generic in `m`. `type Iter e a = IterT e IO a` and
  `type Enumerator e a = EnumeratorT e IO a` keep every existing signature in the HTTP, socket, middleware
  and application layers as it is; nothing outside the two framework modules changes its text.

## Rollout Plan

Each phase is test-first; the tests are listed before the implementation that makes them pass. The gate for
every phase is `make check` green under both compilers.

### Phase 1: generalise the core

Tests, in `test/unit/MicroHttp/IterateeSpec.hs`, over a pure two-layer consumer driven by
`strictEnumerator` at each layer (no files involved):

1. Given `lift` of a base-monad action, when the lifted iteratee is run, then the action's result is the
   iteratee's result and the stream is untouched (a consumer bound after it still receives the chunk).
2. Given a two-layer consumer that reads one chunk from the inner layer and one from the outer (`headChunk`
   and `lift headChunk`), when the inner layer is enumerated with "A" and the base layer with "B", then the
   result is the pair ("A", "B").
3. Given a two-layer consumer whose inner stream ends first, when it reads both, then it sees the inner end
   (`Nothing`) and still reads the outer chunk.
4. Given a failure delivered at the inner layer, when the pair is run through the two-source driver, then
   the outcome is that failure as a single `Left`.
5. Given a failure delivered at the base layer, when run the same way, then the outcome is that failure as
   a single `Left`.
6. The existing `IterateeSpec`, `StreamSpec`, `FormSpec` and middleware cases pass unchanged: the `IO`
   instance behaves as the monomorphic core did.

Implementation:

- [x] `data IterT e m a` with `IterM (m (IterT e m a))`; `type Iter e a = IterT e IO a`;
      `type EnumeratorT e m a = IterT e m a -> m (IterT e m a)`; `type Enumerator e a = EnumeratorT e IO a`.
      `Functor`, `Applicative`, `Monad` instances under `Monad m`.
- [x] `instance MonadTrans (IterT e)` (`lift`), `instance MonadIO m => MonadIO (IterT e m)`; `liftIO`
      re-exported as the class method so `Iteratee.liftIO` callers do not change.
- [x] `run`, `feedStream`, `feedChunk`, `takeN`, `readBodyStrict`, `strictEnumerator`, `byteSinkI`
      (its writer stays `IO`, so it needs `MonadIO`), `onFailure` generalised to `Monad m` or `MonadIO m`
      as each needs; `headChunk :: IterT e m (Maybe ByteString)` added (the spike's `headMaybe`).
      Done 2026-09-13 with one deviation: `onFailure` stayed at `IO` because it uses `Exception.onException`.
      Done 2026-09-14 (review remediation): `onFailure` is generalised to `MonadRelease m`, a class whose
      `IO` instance is `onException` and whose `IterT` instance is `onFailure` itself.
- [x] The two-source driver: `runNested2 :: Monad m => EnumeratorT e (IterT e m) a -> EnumeratorT e m
      (Either e a) -> IterT e (IterT e m) a -> m (Either e a)`, which enumerates the inner layer, runs it,
      enumerates the base layer, runs that, and flattens the two `Either`s. A three-source variant is not
      built until a consumer needs it.
- [x] `make bench-iteratee` before and after, recorded below: the receive path is the hottest `IterM` loop,
      and the dictionary passing `Monad m` adds under mhs is the one cost the type change could have at
      runtime. Done 2026-09-13 with a deviation: the receiver binary was driven by a Python sender, not the
      script's GHC sender, which does not build on this machine (see "Findings from implementation").

### Phase 2: the resource bracket at any layer

Tests, in `test/unit/MicroHttp/IterateeSpec.hs` and `test/unit/MicroHttp/StreamSpec.hs`:

1. Given a `resourceEnumerator` at an inner layer (its consumer's base monad is another iteratee), when the
   consumer completes before the resource is exhausted, then release ran exactly once.
2. Given a `resourceEnumerator` at an inner layer whose consumer fails mid-stream, then release ran exactly
   once.
3. Given `fileEnumeratorChunked` at an inner layer, when a two-layer consumer reads one block from each of
   two files, then it sees the first block of each.

Implementation:

- [x] `resourceEnumerator :: MonadIO m => IO (Maybe r) -> (r -> IO ()) -> (r -> IO ByteString) -> e ->
      EnumeratorT e m a`; acquire, read and release are lifted with `liftIO` inside it. Done 2026-09-13.
      Done 2026-09-14 (review remediation): the constraint is `MonadRelease m`, and each effect step the
      enumerator runs in its base layer is guarded with `releaseOnFailure`, so the bracket also releases
      when the outer stream of a nested consumer fails; a consumer that is mid-effect when acquire fails is
      driven to its next input before the failed end is delivered.
- [x] `fileEnumerator` and `fileEnumeratorChunked` generic in `MonadIO m`; every existing caller infers
      `m = IO`. Done 2026-09-14: generic in `MonadRelease m`, for the reason above.

### Phase 3: `filesEqual` as a nested zip

Tests, in `test/unit/MicroHttp/StreamSpec.hs`, each against a whole-file oracle (`BS.readFile` on both):

1. Identical small files (existing).
2. Same size, one byte different (existing).
3. Different sizes (existing; answered by the size check before any read).
4. Both empty.
5. Identical files spanning several compare blocks.
6. Files that differ only in the block after a block boundary, with the difference straddling the boundary.
7. Same size, differing in the last byte (the whole of both files is read).
8. A missing second file is a failure, not a verdict (existing, with the exact error asserted).

Implementation:

- [x] `filesEqual` keeps its `stat` size shortcut and replaces the two-handle loop with the spike's
      `equalZip` run through `runNested2` over two `fileEnumeratorChunked compareBlockBytes` brackets.
- [x] The hand-rolled loop and its direct `openBinaryFileM`/`hClose` calls are gone from `Stream.hs`;
      `Open` stays only for the write side.
- [x] ADR-0091: the `filesEqual` exception in Consequences and the "Reopens when" paragraph are updated to
      record that the lock-step case is now on the core; `module-index.md` if any row changes; this RFC is
      stamped Implemented and moved to `docs/rfcs/implemented/`, `bun run rfc:index` and `bun run adr:index`
      rerun.

### Findings from implementation (2026-09-13)

- Every phase landed as planned in one sitting; `make check` is green under both compilers with the unit
  suite at 516 examples (was 504): five two-layer cases in `IterateeSpec`, two bracket-at-an-inner-layer
  cases there, and five `filesEqual` and file-enumerator cases in `StreamSpec`.
- Two things GHC and MicroHs disagree on surfaced. A type synonym cannot be partially applied under GHC, so
  the base monad of a nested consumer is written `IterT e IO`, not `Iter e` (mhs accepted the latter). And
  `Iter (..)` in an import list is an error once `Iter` is a synonym; the two bench programs that wrote it
  now import `IterT (..)` and `Iter`.
- `lift` is exported under the module's own name (`Iteratee.lift`) as well as through the `MonadTrans`
  instance, so a nested consumer needs no second import. `liftIO`'s type widened to
  `MonadIO m => IO a -> IterT e m a`; no caller changed.
- `byteSinkI` and `resourceEnumerator` take `MonadIO m` rather than staying at `IO`, since their effects are
  raw `IO` actions the caller supplies; `onFailure` stayed at `IO` because it uses `Exception.onException`
  (superseded by the review remediation below).
- `Stream.compareBlockBytes` is exported so the compare tests can place a difference exactly on a block edge.
- The iteratee bench had rotted since RFC-0038 (it compiled `cbits/` and `src/` from the old layout, and its
  receiver predated the `accept` that returns connection info); its three scripts and the iteratee receiver
  were fixed in this session, and the review of 2026-09-14 found and fixed the same `accept` pattern in the
  other two bench programs. Its GHC sender needs the `network` package, which this machine's cabal index
  does not carry, so `make bench-iteratee` as committed was not what produced the numbers: they were driven
  by a Python `sendall` loop over 256 MiB, two connections per run, against the receiver binary the script
  builds. Before the
  change, one run: plain recv 2068 MB/s, iteratee stream 1505 MB/s. After, three runs: 2054/2009, 2283/2132,
  2120/1797. The iteratee path is not slower for carrying `Monad m`; run-to-run variance is larger than any
  difference, and the single before-run looks like a cold outlier rather than a baseline the change beat.
  On 2026-09-14 the GHC sender was made to build (the Hackage index had never been fetched, and the
  Command Line Tools linker override the Makefile uses for GHC links had to reach the `network` package's
  hsc2hs step too; `test/bench/build-sender.sh` now does both), and `make bench-iteratee` proper ran three
  times over 256 MiB on the remediated tree: plain recv 1930/1933/1880 MB/s, iteratee stream 1545/1874/2014
  MB/s. Same conclusion: the iteratee path is within run-to-run variance of the raw loop.

### Review remediation (2026-09-14)

The code review (`docs/reviews/rfc-0041-code-review-2026-09-14.md`) found two contract breaches in the
driver, both reachable from `filesEqual`, and fixed them:

- An outer enumerator's acquire failure was dropped, because `feedAcquireError` only delivered it to a
  consumer already waiting for input, and under `runNested2` the outer layer starts as an effect step (the
  inner acquire). `filesEqual` then returned a verdict for a second file that stats but does not open.
  `feedAcquireError` now drives effect steps to the next input first.
- The inner bracket did not release when the outer stream failed, because the inner enumerator's effect
  steps run as binds in the outer layer and an outer failure short-circuits past the release. The new
  `MonadRelease` class (`releaseOnFailure :: IO () -> m a -> m a`; `IO` by `onException`, `IterT` by
  `onFailure`) guards each such step. `onFailure` itself is generalised to `MonadRelease m`, so a cleanup
  attached at an inner layer also runs when that layer's base fails.

Four unit cases pin these (three in `IterateeSpec`: outer failure with a counted inner resource, inner
failure with a counted outer resource, outer acquire failure; one in `StreamSpec`: an unopenable same-size
second file is a `Left`), and the shared two-source consumer moved to `TestSupport.Iteratee`. The unit
suite is 520 examples under both compilers.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence, impact, options and a
  recommended path, and continue only with work that does not depend on it.

## Findings from the spike (2026-09-13)

`spike/iteratee-multisource/Spike.hs` (on branch `spike/iteratee-multisource`) implements the generalised
`IterT`, recovers the current core as `IterT e IO`, and rewrites `filesEqual` as `equalZip`. It self-checks
against a naive oracle and passes all six cases above. What it shows about the cost:

- **The type generalisation is small.** `IterM (IO ...)` to `IterM (m ...)`; the type-class instances,
  `feedStream`, `headMaybe` and `run` only thread `m`. `lift` is three lines.
- **The consumer reads like the intent** -- read a block from each stream, compare, recurse -- and each file
  is driven by a real open/read/close enumerator, which is what today's `filesEqual` cannot do.
- **The driver is the sharp edge.** Running a two-layer consumer is a two-`run` dance
  (`enumFile lift … >>= run`, then `enumFile id … >>= run`) returning a per-layer nested `Either`; a
  three-source zip is a three-`run` onion. This is inherent to the encoding and is why the `runZipN` helpers
  are part of the proposal rather than left to callers.
- **`enumFile` grows a rank-2 argument** (`forall x. IO x -> m x`) so its IO reads run at whichever layer it
  feeds. Minor, but it is a signature every generic enumerator would carry.

## References

- Oleg Kiselyov, "Iteratee IO", <https://www.okmij.org/ftp/Haskell/Iteratee/index.html> -- specifically the
  section "Parallel composition of streams: several sources to one sink" (anchor `#2enum1iter`), which shows a
  consumer of type `Iteratee el1 (Iteratee el2 m) a` reading two streams under its own control by using the
  iteratee as its own base monad; and, for contrast, the dual "Parallel composition of iteratees: one source
  to several sinks".
- `spike/iteratee-multisource/Spike.hs` on the `spike/iteratee-multisource` branch (not on `main`) -- the
  working spike and its trailing findings comment.
- ADR-0091 (network and file I/O is block-streaming by default) -- its "Reopens when" records this as the
  path for multi-source combination.
- RFC-0012 (the stream contract and the iteratee core) and RFC-0040 (the constant-space work that surfaced
  this), especially phase 9 and the streamed-diff sequential fan-in via `Iteratee.feedChunk`.

## Open Questions

- **MicroHs feasibility.** Settled 2026-09-13: the spike builds and passes under mhs 0.16.5.0 (see
  "Decision to proceed").
- **Whether to keep `m` fully generic or pin it.** Settled 2026-09-13: generic in `MicroHttp.Iteratee` and
  the `Stream` enumerators, pinned by the `Iter`/`Enumerator` synonyms everywhere else (see "Decision to
  proceed").
- **The performance of nested `IterM`.** Each base-monad step in a nested consumer is an `IterM` wrapping an
  `IterM`; whether that matters for a file compare (few, large blocks) is almost certainly no, but a k-way
  merge over many small records should be measured before it ships.
