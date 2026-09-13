{- | A small, general-purpose iteratee and enumerator core over strict
'BS.ByteString' input in 'IO'. It is deliberately free of any HTTP or
socket vocabulary: the failure type is a parameter @e@, so producers and
consumers in higher layers choose their own error domain. The core machinery
only ever propagates a failure, never constructs one.
-}
module MicroHttp.Iteratee (
    Stream (..),
    Iter (..),
    Enumerator,
    run,
    liftIO,
    takeN,
    readBodyStrict,
    strictEnumerator,
    resourceEnumerator,
    byteSinkI,
    feedChunk,
    onFailure,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString as BS

{- | A unit of stream input: a chunk of bytes, or the end of the stream
carrying an orderly close (@Nothing@) or a failure (@Just@). An empty
'Chunk' means "no data yet" and must not be read as end of stream.
-}
data Stream e
    = Chunk BS.ByteString
    | EndOfStream (Maybe e)
    deriving (Eq, Show)

{- | A stream consumer. @Done@ carries the result and the residual input
beyond what was consumed; @NeedInput@ is a pure continuation awaiting more
input; @IterM@ is an effect step resolved by a driver; @IterFailed@ is a
terminal failure keeping the residue for a handler or keep-alive loop.

The continuation in @NeedInput@ is pure on purpose: with an @IO@
continuation the 'Monad' instance cannot feed residue eagerly, which
deadlocks a consumer that could complete from residue alone. All effects
live in @IterM@ instead.
-}
data Iter e a
    = Done a (Stream e)
    | NeedInput (Stream e -> Iter e a)
    | IterM (IO (Iter e a))
    | IterFailed e (Stream e)

-- | An input producer: it drives an iteratee forward and returns its state.
type Enumerator e a = Iter e a -> IO (Iter e a)

instance Functor (Iter e) where
    fmap f it = case it of
        Done a residue -> Done (f a) residue
        NeedInput k -> NeedInput (fmap f . k)
        IterM m -> IterM (fmap (fmap f) m)
        IterFailed err residue -> IterFailed err residue

instance Applicative (Iter e) where
    pure a = Done a (Chunk BS.empty)
    mf <*> mx = mf >>= \f -> fmap f mx

instance Monad (Iter e) where
    it >>= f = case it of
        Done a residue -> feedStream residue (f a)
        NeedInput k -> NeedInput (k Monad.>=> f)
        IterM m -> IterM (fmap (>>= f) m)
        IterFailed err residue -> IterFailed err residue

{- | Hands a stream value to an iteratee. A waiting consumer receives it; a
resolved consumer keeps its result but adopts the value as its residue, so
bind threads unconsumed input (including an end-of-stream signal) forward.
-}
feedStream :: Stream e -> Iter e a -> Iter e a
feedStream s it = case it of
    NeedInput k -> k s
    Done a _ -> Done a s
    IterFailed err _ -> IterFailed err s
    IterM m -> IterM (fmap (feedStream s) m)

{- | Drives an iteratee to a result, feeding end of stream to a consumer that
still needs input and resolving effect steps. Converts the terminal failure
constructor to 'Left' at the public boundary.
-}
run :: Iter e a -> IO (Either e a)
run it = case it of
    Done a _ -> return (Right a)
    IterFailed err _ -> return (Left err)
    IterM m -> m >>= run
    NeedInput k -> run (k (EndOfStream Nothing))

{- | Lifts an 'IO' action into an iteratee without consuming input, so a
handler can perform effects between stream reads. Residue is threaded by
bind, unchanged across the lifted action.
-}
liftIO :: IO a -> Iter e a
liftIO m = IterM (fmap pure m)

{- | Bounds an inner iteratee to at most @n@ bytes of the outer stream: the
inner sees those bytes then end of stream, and any outer bytes beyond @n@
are preserved as residue. If the inner completes before consuming @n@
bytes, the remainder is not drained; it stays in the outer residue.
-}
takeN :: Int -> Iter e a -> Iter e a
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
readBodyStrict :: e -> Int -> Iter e BS.ByteString
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
strictEnumerator :: BS.ByteString -> Enumerator e a
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
reused by file, and any future, producers.
-}
resourceEnumerator ::
    -- | Acquire; @Nothing@ if it fails.
    IO (Maybe r) ->
    -- | Release, run on every exit after a successful acquire.
    (r -> IO ()) ->
    -- | Read one chunk; an empty result is end of stream.
    (r -> IO BS.ByteString) ->
    -- | Error delivered if acquire fails.
    e ->
    Enumerator e a
resourceEnumerator acquire release readChunk acquireError it0 = do
    opened <- acquire
    case opened of
        Nothing -> return (feedAcquireError it0)
        Just resource -> loop resource it0
  where
    feedAcquireError it = case it of
        NeedInput k -> k (EndOfStream (Just acquireError))
        _ -> it
    loop resource it = case it of
        NeedInput k -> do
            chunk <- readChunk resource
            if BS.null chunk
                then do
                    release resource
                    return (k (EndOfStream Nothing))
                else loop resource (k (Chunk chunk))
        IterM m -> do
            next <- m
            loop resource next
        _ -> do
            release resource
            return it

{- | A sink that writes each chunk with the supplied effectful writer until
end of stream, failing with the writer's error on a failed write. A
transport failure delivered at end of stream is propagated unchanged.
-}
byteSinkI :: (BS.ByteString -> IO (Either e ())) -> Iter e ()
byteSinkI writeBytes = go
  where
    go = NeedInput consume
    consume s = case s of
        Chunk bytes
            | BS.null bytes -> go
            | otherwise -> IterM (sendChunk bytes)
        EndOfStream Nothing -> Done () (EndOfStream Nothing)
        EndOfStream (Just err) -> IterFailed err (EndOfStream (Just err))
    sendChunk bytes = do
        sent <- writeBytes bytes
        case sent of
            Left err -> return (IterFailed err (Chunk BS.empty))
            Right () -> return go

{- | Feeds one chunk to a consumer and resolves any effect it triggers, WITHOUT
signalling end of stream, returning the consumer ready for more input. This is
how a producer that draws from several sources in turn (a page shell, then a
streamed file, then another shell) drives one sink without closing it between
sources; the final end of stream is delivered once, by 'run', when the producer
returns. A resolved or failed consumer is returned unchanged (an empty chunk is
a no-op, matching 'byteSinkI').
-}
feedChunk :: BS.ByteString -> Iter e a -> IO (Iter e a)
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
cleanup runs once, at the first terminal failure.
-}
onFailure :: IO () -> Iter e a -> Iter e a
onFailure cleanup = go
  where
    go it = case it of
        Done a residue -> Done a residue
        IterFailed err residue -> IterM (cleanup >> return (IterFailed err residue))
        IterM m -> IterM (fmap go m)
        NeedInput k -> NeedInput (go . k)
