module MicroHttp.Stream (
    Stream (..),
    Iter (..),
    IterError (..),
    Enumerator,
    run,
    takeN,
    readBodyStrict,
) where

import Control.Monad ((>=>))
import qualified Data.ByteString as BS
import MicroHttp.Http.Parser (ParseError (..))
import MicroHttp.Network.Socket (SocketError)

{- | A unit of stream input: a chunk of bytes, or the end of the stream
carrying an orderly close (@Nothing@) or a transport failure (@Just@).
An empty 'Chunk' means "no data yet" and must not be read as end of stream.
-}
data Stream
    = Chunk BS.ByteString
    | EndOfStream (Maybe SocketError)
    deriving (Eq, Show)

{- | A terminal iteratee failure. Iteratees fail on both sides of the
pipeline, so read and write transport failures are distinct from a
parse or limit failure.
-}
data IterError
    = IterReadError SocketError
    | IterWriteError SocketError
    | IterParseError ParseError
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
data Iter a
    = Done a Stream
    | NeedInput (Stream -> Iter a)
    | IterM (IO (Iter a))
    | IterFailed IterError Stream

-- | An input producer: it drives an iteratee forward and returns its state.
type Enumerator a = Iter a -> IO (Iter a)

instance Functor Iter where
    fmap f it = case it of
        Done a residue -> Done (f a) residue
        NeedInput k -> NeedInput (fmap f . k)
        IterM m -> IterM (fmap (fmap f) m)
        IterFailed err residue -> IterFailed err residue

instance Applicative Iter where
    pure a = Done a (Chunk BS.empty)
    mf <*> mx = mf >>= \f -> fmap f mx

instance Monad Iter where
    it >>= f = case it of
        Done a residue -> feedStream residue (f a)
        NeedInput k -> NeedInput (k >=> f)
        IterM m -> IterM (fmap (>>= f) m)
        IterFailed err residue -> IterFailed err residue

{- | Hands a stream value to an iteratee. A waiting consumer receives it; a
resolved consumer keeps its result but adopts the value as its residue, so
bind threads unconsumed input (including an end-of-stream signal) forward.
-}
feedStream :: Stream -> Iter a -> Iter a
feedStream s it = case it of
    NeedInput k -> k s
    Done a _ -> Done a s
    IterFailed err _ -> IterFailed err s
    IterM m -> IterM (fmap (feedStream s) m)

{- | Drives an iteratee to a result, feeding end of stream to a consumer that
still needs input and resolving effect steps. Converts the terminal failure
constructor to 'Left' at the public boundary.
-}
run :: Iter a -> IO (Either IterError a)
run it = case it of
    Done a _ -> return (Right a)
    IterFailed err _ -> return (Left err)
    IterM m -> m >>= run
    NeedInput k -> run (k (EndOfStream Nothing))

{- | Bounds an inner iteratee to at most @n@ bytes of the outer stream: the
inner sees those bytes then end of stream, and any outer bytes beyond @n@
are preserved as residue. If the inner completes before consuming @n@
bytes, the remainder is not drained; it stays in the outer residue.
-}
takeN :: Int -> Iter a -> Iter a
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

{- | Reads the whole stream into one strict value, failing as
'BodyTooLarge' if the accumulated size would exceed the bound. A handler
that wants a strict body states its own bound with this consumer; the
server's pipeline also installs a default cap.
-}
readBodyStrict :: Int -> Iter BS.ByteString
readBodyStrict limit = go 0 []
  where
    go count acc = NeedInput (consume count acc)
    consume count acc s = case s of
        Chunk bytes
            | BS.null bytes -> go count acc
            | count + BS.length bytes > limit ->
                IterFailed (IterParseError BodyTooLarge) (Chunk bytes)
            | otherwise -> go (count + BS.length bytes) (bytes : acc)
        EndOfStream Nothing -> Done (BS.concat (reverse acc)) (EndOfStream Nothing)
        EndOfStream (Just err) -> IterFailed (IterReadError err) (EndOfStream (Just err))
