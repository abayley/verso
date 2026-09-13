---
id: RFC-0041
name: Multi-source iteratees
status: Draft
owners:
    - Alistair Bayley
created: 2026-09-13
updated: 2026-09-13
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0040]
related_refs:
    - spike/iteratee-multisource/Spike.hs
---

# RFC-0041: Multi-source iteratees

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-09-13 14:00 NZST |
| Started   |                       |
| Completed |                       |

## Summary

The framework's iteratee core (RFC-0012, `MicroHttp.Iteratee`) drives one consumer from one producer, and
that consumer has a single input channel. That fits produce-transform-consume pipelines and sequential
fan-in (feed one sink from several sources in turn), but it cannot express a **lock-step combination of two
sources** -- read a block from each, compare or merge, decide whether to continue -- so the one place that
needs it, `Stream.filesEqual`, is hand-rolled over two raw handles instead of over the file readers. This RFC
proposes generalising the iteratee from its fixed `IO` base to a base-monad-parametric transformer
(`IterT e m a`), so a consumer can nest a second iteratee as its base monad and read both streams under its
own control -- Oleg Kiselyov's "several sources to one sink" (the 2enum1iter construction). A spike
(`spike/iteratee-multisource/Spike.hs`) proves the shape and measures the cost. The change is **not proposed
for adoption now**: it is recorded, with a working spike, so that when a second lock-step or merge consumer
appears (merging sorted index shards is the plausible one) the design and its cost are already understood.

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

- **Adopting the change now.** This RFC records the design and a spike; it is gated on a second lock-step or
  merge consumer. Rewriting the core for one call site is negative net simplicity.
- A second (pull) streaming paradigm alongside the push enumerator.
- Changing the element type. Chunks stay `ByteString`; only the effect layer becomes a parameter.
- Any change to socket or HTTP behaviour. Those layers pin `m = IO` and are unaffected at runtime.

## Proposal

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

## Rollout Plan

Gated: do nothing until the trigger fires.

1. **Trigger.** A second lock-step or merge consumer is needed (the anticipated one is merging sorted link- or
   search-index shards). Until then this RFC stays Draft and `filesEqual` stays hand-rolled (ADR-0091's
   "reopens when").
2. **Confirm MicroHs feasibility.** Port the spike's `IterT`/`lift`/`enumFile` to build under MicroHs, not
   just GHC (Open Questions). If MicroHs cannot express it, this RFC is rejected in favour of the status quo,
   recorded here.
3. **Generalise the core.** Thread `m` through `MicroHttp.Iteratee` and `MicroHttp.Stream`; pin `m = IO` at
   the socket/HTTP boundary; add `lift` and the `runZip2`/`runZip3` helpers. Suites green under both backends.
4. **Move the consumers.** Rewrite `filesEqual` (and the new merge consumer) as nested zips; retire the
   hand-rolled loop; update ADR-0091's `filesEqual` note to "fixed".

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
- `spike/iteratee-multisource/Spike.hs` -- the working spike and its trailing findings comment.
- ADR-0091 (network and file I/O is block-streaming by default) -- its "Reopens when" records this as the
  path for multi-source combination.
- RFC-0012 (the stream contract and the iteratee core) and RFC-0040 (the constant-space work that surfaced
  this), especially phase 9 and the streamed-diff sequential fan-in via `Iteratee.feedChunk`.

## Open Questions

- **MicroHs feasibility.** The spike builds and runs under GHC (`runghc`). The production core must build
  under MicroHs as well. Does MicroHs support the `RankNTypes` argument to `enumFile` and the higher-kinded
  base-monad parametricity `IterT` needs? This must be confirmed before rollout step 3; if not, the RFC is
  rejected (step 2).
- **Whether to keep `m` fully generic or pin it behind `Iter e a = IterT e IO a` almost everywhere.** Fully
  generic signatures propagate the `m` and its constraints into places that only ever use `IO`; pinning early
  keeps inference light but blocks nesting exactly where nesting is wanted. The likely answer is generic in
  `MicroHttp.Iteratee`/`Stream`, pinned at every consumer boundary.
- **The performance of nested `IterM`.** Each base-monad step in a nested consumer is an `IterM` wrapping an
  `IterM`; whether that matters for a file compare (few, large blocks) is almost certainly no, but a k-way
  merge over many small records should be measured before it ships.
