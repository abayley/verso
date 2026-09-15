{- | A small, general-purpose iteratee and enumerator core over strict
'BS.ByteString' input. It is deliberately free of any HTTP or socket
vocabulary: the failure type is a parameter @e@, so producers and consumers in
higher layers choose their own error domain. The core machinery only ever
propagates a failure, never constructs one.

The effect layer is a parameter too (RFC-0041): 'IterT' @e m a@ runs its effect
steps in any monad @m@, and 'Iter' @e a@ is the 'IO' instance every producer and
consumer at the socket and HTTP boundary uses. A consumer that must read two
streams in step nests a second iteratee as its base monad, reads the inner
stream directly and the outer one through 'lift', and is driven by
'runNested2'.
-}
module MicroHttp.Iteratee (
    Stream (..),
    IterT (..),
    Iter,
    EnumeratorT,
    Enumerator,
    run,
    runNested2,
    lift,
    liftIO,
    MonadRelease (..),
    headChunk,
    takeN,
    mapChunksI,
    linesI,
    appendEnumerators,
    readBodyStrict,
    strictEnumerator,
    resourceEnumerator,
    byteSinkI,
    feedChunk,
    feedStream,
    onFailure,
) where

import qualified Control.Exception as Exception
import qualified Control.Monad as Monad
import qualified Control.Monad.IO.Class as IOClass
import qualified Control.Monad.Trans.Class as Trans
import qualified Data.ByteString as BS
import qualified MicroHttp.Bytes as Bytes

{- | A unit of stream input: a chunk of bytes, or the end of the stream
carrying an orderly close (@Nothing@) or a failure (@Just@). An empty
'Chunk' means "no data yet" and must not be read as end of stream.
-}
data Stream e
    = Chunk BS.ByteString
    | EndOfStream (Maybe e)
    deriving (Eq, Show)

{- | A stream consumer whose effect steps run in @m@. @Done@ carries the
result and the residual input beyond what was consumed; @NeedInput@ is a pure
continuation awaiting more input; @IterM@ is an effect step resolved by a
driver; @IterFailed@ is a terminal failure keeping the residue for a handler or
keep-alive loop.

The continuation in @NeedInput@ is pure on purpose: with an effectful
continuation the 'Monad' instance cannot feed residue eagerly, which deadlocks
a consumer that could complete from residue alone. All effects live in @IterM@
instead.
-}
data IterT e m a
    = Done a (Stream e)
    | NeedInput (Stream e -> IterT e m a)
    | IterM (m (IterT e m a))
    | IterFailed e (Stream e)

-- | A consumer whose effects are 'IO': the instance at every socket and HTTP boundary.
type Iter e a = IterT e IO a

-- | An input producer: it drives an iteratee forward in its base monad and returns its state.
type EnumeratorT e m a = IterT e m a -> m (IterT e m a)

-- | A producer in 'IO'.
type Enumerator e a = EnumeratorT e IO a

instance (Functor m) => Functor (IterT e m) where
    fmap f it = case it of
        Done a residue -> Done (f a) residue
        NeedInput k -> NeedInput (fmap f . k)
        IterM m -> IterM (fmap (fmap f) m)
        IterFailed err residue -> IterFailed err residue

instance (Monad m) => Applicative (IterT e m) where
    pure a = Done a (Chunk BS.empty)
    mf <*> mx = mf >>= \f -> fmap f mx

instance (Monad m) => Monad (IterT e m) where
    it >>= f = case it of
        Done a residue -> feedStream residue (f a)
        NeedInput k -> NeedInput (k Monad.>=> f)
        IterM m -> IterM (fmap (>>= f) m)
        IterFailed err residue -> IterFailed err residue

{- | The base monad's actions run as effect steps that consume no input. This
is what lets a consumer nest a second iteratee as its base monad and read that
outer stream: @lift headChunk@ takes a chunk from the outer stream, a bare
@headChunk@ from the inner one (RFC-0041).
-}
instance Trans.MonadTrans (IterT e) where
    lift m = IterM (fmap (\a -> Done a (Chunk BS.empty)) m)

-- | 'IO' reaches any layer whose base monad can run it, so one enumerator serves every layer.
instance (IOClass.MonadIO m) => IOClass.MonadIO (IterT e m) where
    liftIO = Trans.lift . IOClass.liftIO

-- | 'Trans.lift' for this transformer, under the module's own name.
lift :: (Monad m) => m a -> IterT e m a
lift = Trans.lift

{- | A base monad whose own failure can run a release first. 'IO' fails by
exception; an iteratee layer fails by 'IterFailed' at that layer or by a failure
of its own base. 'resourceEnumerator' guards every effect step it runs in its
base monad with this, so a bracket at an inner layer of a nested consumer
releases when the outer stream fails, not only when the consumer it feeds does
(RFC-0041 review).
-}
class (IOClass.MonadIO m) => MonadRelease m where
    -- | Runs the action; if it fails, runs the release once and propagates the failure unchanged.
    releaseOnFailure :: IO () -> m a -> m a

instance MonadRelease IO where
    releaseOnFailure release action = Exception.onException action release

instance (MonadRelease m) => MonadRelease (IterT e m) where
    releaseOnFailure = onFailure

{- | Hands a stream value to an iteratee. A waiting consumer receives it; a
resolved consumer keeps its result but adopts the value as its residue, so
bind threads unconsumed input (including an end-of-stream signal) forward.
-}
feedStream :: (Functor m) => Stream e -> IterT e m a -> IterT e m a
feedStream s it = case it of
    NeedInput k -> k s
    Done a _ -> Done a s
    IterFailed err _ -> IterFailed err s
    IterM m -> IterM (fmap (feedStream s) m)

{- | Drives an iteratee to a result, feeding end of stream to a consumer that
still needs input and resolving effect steps. Converts the terminal failure
constructor to 'Left' at the public boundary.
-}
run :: (Monad m) => IterT e m a -> m (Either e a)
run it = case it of
    Done a _ -> return (Right a)
    IterFailed err _ -> return (Left err)
    IterM m -> m >>= run
    NeedInput k -> run (k (EndOfStream Nothing))

{- | Lifts an 'IO' action into an iteratee without consuming input, so a
handler can perform effects between stream reads. Residue is threaded by
bind, unchanged across the lifted action. At any layer whose base monad
can run 'IO', which is every layer of a nested consumer over 'Iter'.
-}
liftIO :: (IOClass.MonadIO m) => IO a -> IterT e m a
liftIO = IOClass.liftIO

{- | Runs a two-source consumer (RFC-0041): one whose base monad is itself an
iteratee, so that it reads the inner stream directly and the outer stream
through 'lift'. The inner enumerator feeds the inner layer, the outer feeds
the base layer, and the two layers' outcomes are flattened to one: a failure
at either layer is the failure. Each enumerator owns its own resource
bracket, and each guards the effect steps it runs in its base layer, so both
sources are released however the consumer stops, including when the outer
stream fails while the inner bracket is open.
-}
runNested2 ::
    (Monad m) =>
    -- | Feeds the inner stream (the consumer's direct input).
    EnumeratorT e (IterT e m) a ->
    -- | Feeds the outer stream (the consumer's base monad).
    EnumeratorT e m (Either e a) ->
    IterT e (IterT e m) a ->
    m (Either e a)
runNested2 inner outer consumer = do
    outcome <- outer (inner consumer >>= run) >>= run
    pure (Monad.join outcome)

{- | The next non-empty chunk of the stream, or @Nothing@ at its orderly end;
a failed end fails the consumer. The reading primitive of a lock-step
consumer, which takes one chunk from each of its streams per step.
-}
headChunk :: IterT e m (Maybe BS.ByteString)
headChunk = NeedInput next
  where
    next s = case s of
        Chunk bytes
            | BS.null bytes -> headChunk
            | otherwise -> Done (Just bytes) (Chunk BS.empty)
        EndOfStream Nothing -> Done Nothing (EndOfStream Nothing)
        EndOfStream (Just err) -> IterFailed err (EndOfStream (Just err))

{- | Bounds an inner iteratee to at most @n@ bytes of the outer stream: the
inner sees those bytes then end of stream, and any outer bytes beyond @n@
are preserved as residue. If the inner completes before consuming @n@
bytes, the remainder is not drained; it stays in the outer residue.
-}
takeN :: (Functor m) => Int -> IterT e m a -> IterT e m a
takeN = go
  where
    go budget inner = case inner of
        Done a residue -> Done a residue
        IterFailed err residue -> IterFailed err residue
        IterM m -> IterM (fmap (go budget) m)
        NeedInput k
            | budget <= 0 -> finish BS.empty (k (EndOfStream Nothing))
            | otherwise -> NeedInput (feed budget k)

    feed budget k s = case s of
        EndOfStream merr -> finish BS.empty (k (EndOfStream merr))
        Chunk bytes
            | BS.null bytes -> NeedInput (feed budget k)
            | BS.length bytes <= budget -> go (budget - BS.length bytes) (k (Chunk bytes))
            | otherwise ->
                let (toInner, rest) = BS.splitAt budget bytes
                 in finish rest (k (Chunk toInner))

    -- The budget is spent; force the inner to resolve on end of stream and
    -- prepend any held-back bytes to its residue.
    finish rest inner = case inner of
        Done a residue -> Done a (prepend rest residue)
        IterFailed err residue -> IterFailed err (prepend rest residue)
        IterM m -> IterM (fmap (finish rest) m)
        NeedInput k -> finish rest (k (EndOfStream Nothing))

    prepend rest residue = case residue of
        Chunk bytes -> Chunk (BS.append rest bytes)
        EndOfStream _ -> Chunk rest

{- | A chunk transformer with a small carry (RFC-0043): each chunk, prefixed by
the carry, is turned by @blockStep@ into output bytes for the inner sink and a
new carry; at end of stream the carry is flushed through @finish@ and the inner
sink is ended. An inner sink that completes or fails early is returned as is,
and a failed end of stream reaches it unchanged. This is the general form of
the form decoder and the newline normaliser ('MicroHttp.Form').

A chunk is worked in slices of at most 'sliceBytes', whatever size the producer
delivers: a block step may build a per-block list, and a list proportional to
an arbitrary chunk is the MicroHs evaluator-stack hazard (a whole-body chunk
from a strict producer). The slice, not the chunk, bounds every intermediate.
-}
mapChunksI :: (Monad m) => (BS.ByteString -> (BS.ByteString, BS.ByteString)) -> (BS.ByteString -> BS.ByteString) -> IterT e m a -> IterT e m a
mapChunksI blockStep finish = go BS.empty
  where
    go carry inner = case inner of
        NeedInput _ -> NeedInput (step carry inner)
        IterM m -> IterM (fmap (go carry) m)
        other -> other
    step carry inner s = case s of
        Chunk bytes
            | BS.null bytes -> go carry inner
            | otherwise -> IterM (slices carry inner bytes)
        EndOfStream Nothing -> IterM $ do
            inner' <- feedChunk (finish carry) inner
            pure (endWith Nothing inner')
        EndOfStream (Just err) -> endWith (Just err) inner
    -- Feeds one slice at a time; stops early if the inner sink resolves.
    slices carry inner bytes
        | BS.null bytes = pure (go carry inner)
        | otherwise = do
            let (slice, rest) = BS.splitAt sliceBytes bytes
                (out, carry') = blockStep (BS.append carry slice)
            inner' <- feedChunk out inner
            case inner' of
                NeedInput _ -> slices carry' inner' rest
                other -> pure other

-- | The most bytes a 'mapChunksI' block step sees at once, whatever the producer's chunk size.
sliceBytes :: Int
sliceBytes = 4096

-- | Delivers an end of stream to a sink once it is waiting for input; a resolved sink is returned as is.
endWith :: (Functor m) => Maybe e -> IterT e m a -> IterT e m a
endWith merr inner = case inner of
    NeedInput k -> k (EndOfStream merr)
    IterM m -> IterM (fmap (endWith merr) m)
    other -> other

{- | A line transformer (RFC-0043): the inner sink sees one line per chunk, each
with its terminating newline (so a blank line is a @"\n"@ chunk, not an empty
one that consumers skip), and a final unterminated line as the last chunk.
Carriage returns stay with their line. The carry across chunk boundaries is the
open line, so what is live is one producer chunk plus one line. An inner sink
that completes or fails early is returned as is; a failed end reaches it.
-}
linesI :: (Monad m) => IterT e m a -> IterT e m a
linesI = go BS.empty
  where
    go carry inner = case inner of
        NeedInput _ -> NeedInput (step carry inner)
        IterM m -> IterM (fmap (go carry) m)
        other -> other
    step carry inner s = case s of
        Chunk bytes
            | BS.null bytes -> go carry inner
            | otherwise ->
                let hay = if BS.null carry then bytes else BS.append carry bytes
                    parts = Bytes.split '\n' hay -- non-empty; the last part is the open line
                 in IterM (feedLines (init parts) (last parts) inner)
        EndOfStream Nothing
            | BS.null carry -> endWith Nothing inner
            | otherwise -> IterM $ do
                inner' <- feedChunk carry inner
                pure (endWith Nothing inner')
        EndOfStream (Just err) -> endWith (Just err) inner
    feedLines [] carry inner = pure (go carry inner)
    feedLines (line : rest) carry inner = do
        inner' <- feedChunk (BS.snoc line 10) inner
        case inner' of
            NeedInput _ -> feedLines rest carry inner'
            other -> pure other

{- | One source from several, in order (RFC-0043): each enumerator runs in turn
with its own bracket, and the consumer sees their bytes as one stream with one
end, delivered by the driver. An enumerator ends the stream it feeds when its
own bytes run out, so the consumer is shielded while each runs: an orderly end
from a source is absorbed and the consumer stays waiting for the next; a failed
end and the consumer's own completion or failure pass through, and the sources
after them are never started.
-}
appendEnumerators :: (Monad m) => [EnumeratorT e m a] -> EnumeratorT e m a
appendEnumerators sources it0 = case sources of
    [] -> return it0
    (source : rest) -> do
        after <- source (shield it0)
        case after of
            NeedInput _ -> appendEnumerators rest after
            _ -> return after
  where
    -- The consumer with one orderly end absorbed: that end yields the consumer as it
    -- was, unshielded and still waiting, which is what the next source receives.
    shield it = case it of
        NeedInput k -> NeedInput (absorb it k)
        IterM m -> IterM (fmap shield m)
        other -> other
    absorb it k s = case s of
        EndOfStream Nothing -> it
        other -> shield (k other)

{- | Reads the whole stream into one strict value, failing with the supplied
error if the accumulated size would exceed the bound. The over-limit error
is a parameter so the core stays free of any domain vocabulary; a transport
failure delivered at end of stream is propagated unchanged.

Chunks are accumulated by @cons@ (O(1)) and joined with a single 'BS.concat' at the end,
never by appending onto a growing buffer per chunk: in mhs @append@ memcpys, so a
per-chunk append would be O(bodySize * chunkCount). 'BS.concat' over k pieces is still
@foldr append@ (O(total * k)); for very large bodies arriving in very many chunks that
itself is superlinear -- if request ingest ever profiles slow, a single-allocation concat
is the fix (mhs ByteString cost model: docs/design/link-index-performance.md).
-}
readBodyStrict :: e -> Int -> IterT e m BS.ByteString
readBodyStrict tooLarge limit = go 0 []
  where
    go count acc = NeedInput (consume count acc)
    consume count acc s = case s of
        Chunk bytes
            | BS.null bytes -> go count acc
            | count + BS.length bytes > limit -> IterFailed tooLarge (Chunk bytes)
            | otherwise -> go (count + BS.length bytes) (bytes : acc)
        EndOfStream Nothing -> Done (BS.concat (reverse acc)) (EndOfStream Nothing)
        EndOfStream (Just err) -> IterFailed err (EndOfStream (Just err))

{- | Feeds a strict value to a consumer as a single chunk, then end of
stream. The value is already in memory, so one chunk suffices.
-}
strictEnumerator :: (Monad m) => BS.ByteString -> EnumeratorT e m a
strictEnumerator = loop
  where
    loop remaining it = case it of
        NeedInput k
            | BS.null remaining -> return (k (EndOfStream Nothing))
            | otherwise -> loop BS.empty (k (Chunk remaining))
        IterM m -> m >>= loop remaining
        _ -> return it

{- | Streams a resource the producer owns: it acquires, feeds chunks
(an empty read is end of stream), and releases on every exit path,
including a consumer that completes early or fails mid-stream. A failed
acquire ends the stream with the supplied error and nothing to release.
This is the model's resource-bracketing guarantee, expressed once and
reused by file, and any future, producers. The acquire, read and release are
'IO'; the layer fed is any that can run 'IO' and release on its own failure
('MonadRelease'), so the same bracket serves a consumer at the base layer and
either stream of a nested one (RFC-0041). A consumer that is mid-effect when
acquire fails is driven to its next input before the failed end is delivered.
-}
resourceEnumerator ::
    (MonadRelease m) =>
    -- | Acquire; @Nothing@ if it fails.
    IO (Maybe r) ->
    -- | Release, run on every exit after a successful acquire.
    (r -> IO ()) ->
    -- | Read one chunk; an empty result is end of stream.
    (r -> IO BS.ByteString) ->
    -- | Error delivered if acquire fails.
    e ->
    EnumeratorT e m a
resourceEnumerator acquire release readChunk acquireError it0 = do
    opened <- IOClass.liftIO acquire
    case opened of
        Nothing -> feedAcquireError it0
        Just resource -> loop resource it0
  where
    feedAcquireError it = case it of
        NeedInput k -> return (k (EndOfStream (Just acquireError)))
        IterM m -> m >>= feedAcquireError
        _ -> return it
    loop resource it = case it of
        NeedInput k -> do
            chunk <- IOClass.liftIO (readChunk resource)
            if BS.null chunk
                then do
                    IOClass.liftIO (release resource)
                    return (k (EndOfStream Nothing))
                else loop resource (k (Chunk chunk))
        IterM m -> do
            next <- releaseOnFailure (release resource) m
            loop resource next
        _ -> do
            IOClass.liftIO (release resource)
            return it

{- | A sink that writes each chunk with the supplied effectful writer until
end of stream, failing with the writer's error on a failed write. A
transport failure delivered at end of stream is propagated unchanged.
-}
byteSinkI :: (IOClass.MonadIO m) => (BS.ByteString -> IO (Either e ())) -> IterT e m ()
byteSinkI writeBytes = go
  where
    go = NeedInput consume
    consume s = case s of
        Chunk bytes
            | BS.null bytes -> go
            | otherwise -> IterM (fmap afterWrite (IOClass.liftIO (writeBytes bytes)))
        EndOfStream Nothing -> Done () (EndOfStream Nothing)
        EndOfStream (Just err) -> IterFailed err (EndOfStream (Just err))
    afterWrite sent = case sent of
        Left err -> IterFailed err (Chunk BS.empty)
        Right () -> go

{- | Feeds one chunk to a consumer and resolves any effect it triggers, WITHOUT
signalling end of stream, returning the consumer ready for more input. This is
how a producer that draws from several sources in turn (a page shell, then a
streamed file, then another shell) drives one sink without closing it between
sources; the final end of stream is delivered once, by 'run', when the producer
returns. A resolved or failed consumer is returned unchanged (an empty chunk is
a no-op, matching 'byteSinkI').
-}
feedChunk :: (Monad m) => BS.ByteString -> IterT e m a -> m (IterT e m a)
feedChunk bytes it
    | BS.null bytes = resolve it
    | otherwise = case it of
        NeedInput k -> resolve (k (Chunk bytes))
        IterM m -> m >>= feedChunk bytes
        other -> return other
  where
    resolve x = case x of
        IterM m -> m >>= resolve
        other -> return other

{- | Runs a cleanup action if the iteratee fails, then propagates the failure
unchanged; a consumer that completes runs nothing. This is how a handler that
has reserved a resource for a consumer (a temp file a sink writes into) releases
it when the consumer, or the stream feeding it, fails part-way (RFC-0042). The
cleanup runs once, at the first terminal failure, whether that is a failed
iteratee value, a failure of the base layer under a nested consumer, or an
exception thrown by one of its effect steps (a write that fails with the disk
full); the exception is rethrown after the cleanup.
-}
onFailure :: (MonadRelease m) => IO () -> IterT e m a -> IterT e m a
onFailure cleanup = go
  where
    go it = case it of
        Done a residue -> Done a residue
        IterFailed err residue -> IterM (IOClass.liftIO cleanup >> return (IterFailed err residue))
        IterM m -> IterM (releaseOnFailure cleanup (fmap go m))
        NeedInput k -> NeedInput (go . k)
