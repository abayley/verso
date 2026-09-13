{- | A streaming consumer for @application/x-www-form-urlencoded@ request bodies
(RFC-0042). The body is parsed as a sequence of parts; each part's decoded name
arrives before its value, and the value is streamed -- still percent-encoded -- to
a sink chosen from that name. Fields with no sink of their own are decoded and
collected in memory under a per-field cap, a total cap and a count cap, so a form
with one document-sized field never holds that field as a value: the caller
routes it to a file sink and decodes it on the way with 'decodeFormValueI'.

Every scan is an index loop over the chunk in hand ('MicroHttp.Bytes'), never an
@unpack@, and the decoders emit their output a block at a time into the next
sink, so nothing here is proportional to a value's length. The wire semantics are
those of the whole-body parser this replaces: only the first @=@ separates a
name from its value, a field with no @=@ has an empty value, an empty field
between two @&@ is a field with an empty name, an empty body has no fields, a
@+@ is a space, and a malformed @%@ escape passes through verbatim.

A sink is chosen when the name arrives, so the choice cannot depend on a field
that comes later; a form that needs control fields before its large field puts
them first (browsers preserve document order).
-}
module MicroHttp.Form (
    FormLimits (..),
    PartSink (..),
    formI,
    decodeFormValueI,
    normaliseNewlinesI,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Bytes as Bytes
import qualified MicroHttp.Iteratee as Iteratee

-- | The caps a form observes on the fields it collects in memory.
data FormLimits = FormLimits
    { maxFieldBytes :: Int
    -- ^ Decoded bytes per collected field (and per name).
    , maxCollectedBytes :: Int
    -- ^ Decoded bytes across every collected field.
    , maxFields :: Int
    -- ^ Parts in the form, collected or routed.
    }
    deriving (Eq, Show)

-- | What to do with one part's value, chosen from its decoded name.
data PartSink e a
    = -- | Decode the value and collect it in memory, under 'maxFieldBytes'.
      CollectField
    | -- | Stream the raw, still-encoded value bytes to this sink; it decodes.
      SinkPart (Iteratee.Iter e a)

{- | Consumes a urlencoded body: the collected fields, decoded, in arrival order,
and the result of every routed sink paired with its field name, also in order. A
cap exceeded, or a routed sink that fails, fails the form with that error (the
cap failures carry the supplied error) and the unread bytes as residue.
-}
formI :: FormLimits -> e -> (BS.ByteString -> PartSink e a) -> Iteratee.Iter e ([(BS.ByteString, BS.ByteString)], [(BS.ByteString, a)])
formI limits tooLarge route = inName initial [] False
  where
    initial = Totals 0 0 [] []

    -- Reading a name: the bytes seen so far (reversed chunks), whether a part is
    -- pending (any name byte, or an '&' just consumed, makes an empty field real).
    inName totals acc pending = Iteratee.NeedInput $ \s -> case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> inName totals acc pending
            | otherwise -> nameBytes totals acc pending bytes
        Iteratee.EndOfStream Nothing
            | pending -> completeEmpty totals (BS.concat (reverse acc)) finished
            | otherwise -> finished totals
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err s

    nameBytes totals acc pending bytes =
        case (Bytes.indexOf '=' bytes, Bytes.indexOf '&' bytes) of
            (Nothing, Nothing) -> withNameBytes totals (BS.concat (reverse (bytes : acc))) (\_ -> inName totals (bytes : acc) True)
            (Just eq, Just amp)
                | amp < eq -> emptyValueAt totals acc bytes amp
                | otherwise -> valueAt totals acc bytes eq
            (Just eq, Nothing) -> valueAt totals acc bytes eq
            (Nothing, Just amp) -> emptyValueAt totals acc bytes amp
      where
        -- A field ends with no '=': its value is empty, and the rest is the next name.
        emptyValueAt t a b amp =
            let name = BS.concat (reverse (BS.take amp b : a))
             in withNameBytes t name (\_ -> completeEmpty t name (\t' -> resume t' (BS.drop (amp + 1) b)))
        -- The '=' ends the name: decode it, choose the sink, and start the value.
        valueAt t a b eq =
            let raw = BS.concat (reverse (BS.take eq b : a))
             in withNameBytes t raw $ \_ -> Iteratee.IterM $ do
                    decoded <- decodeName raw
                    case decoded of
                        Left err -> pure (Iteratee.IterFailed err (Iteratee.Chunk (BS.drop (eq + 1) b)))
                        Right name -> pure (startValue t name (BS.drop (eq + 1) b))

    -- The name cap: a name longer than a field is refused before it is decoded.
    withNameBytes totals bytes k
        | BS.length bytes > maxFieldBytes limits = Iteratee.IterFailed tooLarge (Iteratee.Chunk BS.empty)
        | otherwise = k totals

    decodeName raw = Iteratee.strictEnumerator raw (decodeFormValueI (Iteratee.readBodyStrict tooLarge (maxFieldBytes limits))) >>= Iteratee.run

    -- Begin a part's value: pick its sink from the name, then consume the rest of the chunk as value bytes.
    startValue totals name rest =
        case route name of
            CollectField -> valueBytes totals (Collecting name (decodeFormValueI (Iteratee.readBodyStrict tooLarge (maxFieldBytes limits)))) rest
            SinkPart sink -> valueBytes totals (Sinking name sink) rest

    -- Reading a value: bytes up to the next '&' go to the part's sink.
    inValue totals part = Iteratee.NeedInput $ \s -> case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> inValue totals part
            | otherwise -> valueBytes totals part bytes
        Iteratee.EndOfStream Nothing -> completePart totals part finished
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err s

    valueBytes totals part bytes =
        case Bytes.indexOf '&' bytes of
            Nothing -> Iteratee.IterM $ do
                part' <- feedPart part bytes
                pure (either (uncurry Iteratee.IterFailed) (inValue totals) part')
            Just amp -> Iteratee.IterM $ do
                part' <- feedPart part (BS.take amp bytes)
                pure $ case part' of
                    Left (err, residue) -> Iteratee.IterFailed err residue
                    Right fed -> completePart totals fed (\t -> resume t (BS.drop (amp + 1) bytes))

    -- After an '&': the next name starts in what is left of this chunk.
    resume totals rest
        | BS.null rest = inName totals [] True
        | otherwise = nameBytes totals [] True rest

    -- Feeds value bytes to the part's sink; a sink that has already failed ends the form.
    feedPart part bytes = case part of
        Collecting name it -> classify (Collecting name) <$> Iteratee.feedChunk bytes it
        Sinking name it -> classify (Sinking name) <$> Iteratee.feedChunk bytes it
    classify rebuild it = case it of
        Iteratee.IterFailed err residue -> Left (err, residue)
        other -> Right (rebuild other)

    -- A part's value has ended: run its sink to completion and record the result.
    completePart totals part k = Iteratee.IterM $ case part of
        Collecting name it -> do
            outcome <- Iteratee.run it
            pure $ case outcome of
                Left err -> Iteratee.IterFailed err (Iteratee.Chunk BS.empty)
                Right value -> recordField totals name value k
        Sinking name it -> do
            outcome <- Iteratee.run it
            pure $ case outcome of
                Left err -> Iteratee.IterFailed err (Iteratee.Chunk BS.empty)
                Right a -> countPart totals (\t -> k t{sunk = (name, a) : sunk t})

    -- A field with no '=' has an empty value; its name is still decoded and capped.
    completeEmpty totals raw k = Iteratee.IterM $ do
        decoded <- decodeName raw
        pure $ case decoded of
            Left err -> Iteratee.IterFailed err (Iteratee.Chunk BS.empty)
            Right name -> recordField totals name BS.empty k

    recordField totals name value k =
        let total' = collectedBytes totals + BS.length value
         in if total' > maxCollectedBytes limits
                then Iteratee.IterFailed tooLarge (Iteratee.Chunk BS.empty)
                else countPart totals (\t -> k t{collectedBytes = total', fields = (name, value) : fields t})

    countPart totals k
        | partCount totals + 1 > maxFields limits = Iteratee.IterFailed tooLarge (Iteratee.Chunk BS.empty)
        | otherwise = k totals{partCount = partCount totals + 1}

    finished totals = Iteratee.Done (reverse (fields totals), reverse (sunk totals)) (Iteratee.Chunk BS.empty)

-- | The running tallies and results of a form being consumed.
data Totals a = Totals
    { partCount :: Int
    , collectedBytes :: Int
    , fields :: [(BS.ByteString, BS.ByteString)]
    , sunk :: [(BS.ByteString, a)]
    }

-- | The part whose value is being read: a collected field or a routed one, with its sink.
data Part e a
    = Collecting BS.ByteString (Iteratee.Iter e BS.ByteString)
    | Sinking BS.ByteString (Iteratee.Iter e a)

{- | Percent-decodes a stream of urlencoded value bytes into the given sink, a
block at a time: @+@ becomes a space, @%XX@ becomes the byte, and a malformed
escape passes through verbatim. An escape split across a block boundary is
carried (at most two bytes: a @%@ and one hex digit) into the next block; at end
of stream the carry is flushed verbatim, as the whole-value decoder left a
trailing bare @%@ or truncated escape. The inner sink's end of stream follows
the flush.
-}
decodeFormValueI :: Iteratee.Iter e a -> Iteratee.Iter e a
decodeFormValueI = transformI decodeBlock id

{- | Normalises line ends in a stream into the given sink: @CRLF@ and a lone @CR@
both become @LF@. A @CR@ at a block end is carried to see whether an @LF@
follows; at end of stream a carried @CR@ is emitted as @LF@.
-}
normaliseNewlinesI :: Iteratee.Iter e a -> Iteratee.Iter e a
normaliseNewlinesI = transformI newlineBlock (\carry -> if BS.null carry then carry else BS.singleton '\n')

{- | A block transformer with a small carry: each chunk (prefixed by the carry) is
turned into output bytes and a new carry; at end of stream the carry is flushed
through @finish@ and the inner sink is ended. An inner sink that completes or
fails early is returned as is.

A chunk is worked in slices of at most 'sliceBytes', whatever size the producer
delivers: the block steps build their output as a per-block list, and a list
proportional to an arbitrary chunk is the evaluator-stack hazard this module
exists to avoid (a whole-body chunk from a strict producer would otherwise
reintroduce it). The slice, not the chunk, bounds every intermediate.
-}
transformI :: (BS.ByteString -> (BS.ByteString, BS.ByteString)) -> (BS.ByteString -> BS.ByteString) -> Iteratee.Iter e a -> Iteratee.Iter e a
transformI blockStep finish = go BS.empty
  where
    go carry inner = case inner of
        Iteratee.NeedInput _ -> Iteratee.NeedInput (step carry inner)
        Iteratee.IterM m -> Iteratee.IterM (fmap (go carry) m)
        other -> other
    step carry inner s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go carry inner
            | otherwise -> Iteratee.IterM (slices carry inner bytes)
        Iteratee.EndOfStream Nothing -> Iteratee.IterM $ do
            inner' <- Iteratee.feedChunk (finish carry) inner
            pure (end inner')
        Iteratee.EndOfStream (Just err) -> endWith (Just err) inner
    -- Feeds one slice at a time; stops early if the inner sink resolves.
    slices carry inner bytes
        | BS.null bytes = pure (go carry inner)
        | otherwise = do
            let (slice, rest) = BS.splitAt sliceBytes bytes
                (out, carry') = blockStep (BS.append carry slice)
            inner' <- Iteratee.feedChunk out inner
            case inner' of
                Iteratee.NeedInput _ -> slices carry' inner' rest
                other -> pure other
    end = endWith Nothing
    -- Delivers the end of stream to the inner sink once it is waiting for input.
    endWith merr inner = case inner of
        Iteratee.NeedInput k -> k (Iteratee.EndOfStream merr)
        Iteratee.IterM m -> Iteratee.IterM (fmap (endWith merr) m)
        other -> other

-- | The most bytes a block step sees at once, whatever the producer's chunk size.
sliceBytes :: Int
sliceBytes = 4096

{- | Decodes one block: the decoded bytes, and the undecodable tail (a @%@ with
fewer than two bytes after it) to carry into the next block. A per-block list is
packed once; a block is at most a stream chunk plus two bytes.
-}
decodeBlock :: BS.ByteString -> (BS.ByteString, BS.ByteString)
decodeBlock bytes = (BS.pack (go 0), carry)
  where
    len = BS.length bytes
    -- Where the carry starts: found by the same left-to-right walk the decoder
    -- takes, so an escape's three bytes are never split from each other and a
    -- '%' that is itself the tail of a malformed escape is not mistaken for a carry.
    cut = scan 0
    scan i
        | i >= len = len
        | BS.index bytes i /= '%' = scan (i + 1)
        | i + 2 < len = scan (i + 3)
        | otherwise = i
    carry = BS.drop cut bytes
    go i
        | i >= cut = []
        | c == '+' = ' ' : go (i + 1)
        | c == '%' =
            case hexPair (BS.index bytes (i + 1)) (BS.index bytes (i + 2)) of
                Just decoded -> decoded : go (i + 3)
                Nothing -> c : BS.index bytes (i + 1) : BS.index bytes (i + 2) : go (i + 3)
        | otherwise = c : go (i + 1)
      where
        c = BS.index bytes i

-- | Normalises one block's line ends; a trailing CR is the carry.
newlineBlock :: BS.ByteString -> (BS.ByteString, BS.ByteString)
newlineBlock bytes
    | BS.null bytes = (bytes, BS.empty)
    | Maybe.isNothing (Bytes.indexOf '\r' bytes) = (bytes, BS.empty)
    | otherwise = (BS.pack (go 0), carry)
  where
    len = BS.length bytes
    cut = if BS.index bytes (len - 1) == '\r' then len - 1 else len
    carry = BS.drop cut bytes
    go i
        | i >= cut = []
        | c /= '\r' = c : go (i + 1)
        | i + 1 < len && BS.index bytes (i + 1) == '\n' = '\n' : go (i + 2)
        | otherwise = '\n' : go (i + 1)
      where
        c = BS.index bytes i

-- | The byte for two hex digits, or Nothing when either is not a hex digit.
hexPair :: Char -> Char -> Maybe Char
hexPair a b
    | Char.isHexDigit a && Char.isHexDigit b = Just (Char.chr (Char.digitToInt a * 16 + Char.digitToInt b))
    | otherwise = Nothing
