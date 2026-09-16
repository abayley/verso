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
between two @&@ is a field with an empty name, an empty body has no fields, and
a @+@ is a space. Percent-decoding itself is 'MicroHttp.Percent', shared with the
path and query decoders: a @%@ that does not begin a valid escape is emitted as
itself and the scan moves on by one.

A sink is chosen when the name arrives, so the choice cannot depend on a field
that comes later; a form that needs control fields before its large field puts
them first (browsers preserve document order).
-}
module MicroHttp.Form (
    FormLimits (..),
    FormResult (..),
    PartSink (..),
    formI,
    decodeFormValueI,
    normaliseNewlinesI,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Bytes as Bytes
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Percent as Percent

-- | The caps a form observes on the fields it collects in memory.
data FormLimits = FormLimits
    { maxFieldBytes :: Int
    -- ^ Decoded bytes per collected field's value (and per name, collected or routed).
    , maxCollectedBytes :: Int
    -- ^ Decoded bytes across every collected field, names and values together.
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

-- | What a consumed form yields: both lists are in arrival order.
data FormResult a = FormResult
    { collectedFields :: [(BS.ByteString, BS.ByteString)]
    -- ^ The decoded name and value of every field that was not routed.
    , routedResults :: [(BS.ByteString, a)]
    -- ^ The decoded name and the sink's result of every routed part.
    }
    deriving (Eq, Show)

{- | Consumes a urlencoded body into a 'FormResult'. A cap exceeded fails the
form with the supplied error; a routed sink that fails, or a stream that fails
mid-body, fails it with that error, and a part whose value was being streamed
when the stream failed is handed the failed end first, so its sink releases what
it holds. The residue of a failed form is not meaningful: the server answers an
error and closes the connection without resuming the stream, so nothing reads it.
-}
formI :: FormLimits -> e -> (BS.ByteString -> PartSink e a) -> Iteratee.Iter e (FormResult a)
formI limits tooLarge route = inName initial [] False
  where
    initial = Totals 0 0 [] []
    record = recordField limits tooLarge
    count = countPart limits tooLarge

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

    -- The name is held as its chunks until it ends, so a name spread over many
    -- small chunks costs one concatenation, not one per chunk; only its length
    -- is checked as it grows.
    nameBytes totals acc pending bytes =
        case (Bytes.indexOf '=' bytes, Bytes.indexOf '&' bytes) of
            (Nothing, Nothing) -> withinNameCap (bytes : acc) (inName totals (bytes : acc) True)
            (Just eq, Just amp)
                | amp < eq -> emptyValueAt totals acc bytes amp
                | otherwise -> valueAt totals acc bytes eq
            (Just eq, Nothing) -> valueAt totals acc bytes eq
            (Nothing, Just amp) -> emptyValueAt totals acc bytes amp
      where
        -- A field ends with no '=': its value is empty, and the rest is the next name.
        emptyValueAt t a b amp =
            let raw = BS.take amp b : a
             in withinNameCap raw (completeEmpty t (BS.concat (reverse raw)) (\t' -> resume t' (BS.drop (amp + 1) b)))
        -- The '=' ends the name: decode it, choose the sink, and start the value.
        valueAt t a b eq =
            let raw = BS.take eq b : a
             in withinNameCap raw $ Iteratee.IterM $ do
                    decoded <- decodeName (BS.concat (reverse raw))
                    pure $ case decoded of
                        Left err -> failWith err
                        Right name -> startValue t name (BS.drop (eq + 1) b)

    -- The name cap: a name longer than a field is refused before it is decoded.
    withinNameCap raw k
        | sum (map BS.length raw) > maxFieldBytes limits = failWith tooLarge
        | otherwise = k

    decodeName raw = Iteratee.strictEnumerator raw cappedCollector >>= Iteratee.run

    -- A collected value's sink: decoded into memory under the per-field cap.
    cappedCollector = decodeFormValueI (Iteratee.readBodyStrict tooLarge (maxFieldBytes limits))

    -- Begin a part's value: pick its sink from the name, then consume the rest of the chunk as value bytes.
    startValue totals name rest =
        case route name of
            CollectField -> valueBytes totals (Collecting name cappedCollector) rest
            SinkPart sink -> valueBytes totals (Sinking name sink) rest

    -- Reading a value: bytes up to the next '&' go to the part's sink.
    inValue totals part = Iteratee.NeedInput $ \s -> case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> inValue totals part
            | otherwise -> valueBytes totals part bytes
        Iteratee.EndOfStream Nothing -> completePart totals part finished
        Iteratee.EndOfStream (Just err) -> Iteratee.IterM (abandonPart part s >> pure (Iteratee.IterFailed err s))

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

    -- A part's value has ended: run its sink to completion and record the result.
    completePart totals part k = Iteratee.IterM $ case part of
        Collecting name it -> do
            outcome <- Iteratee.run it
            pure (either failWith (\value -> record totals name value k) outcome)
        Sinking name it -> do
            outcome <- Iteratee.run it
            pure (either failWith (\a -> count totals (\t -> k t{sunk = (name, a) : sunk t})) outcome)

    -- A field with no '=' has an empty value; its name is still decoded and capped.
    completeEmpty totals raw k = Iteratee.IterM $ do
        decoded <- decodeName raw
        pure (either failWith (\name -> record totals name BS.empty k) decoded)

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

-- | Fails the form. The residue is not meaningful (see 'formI').
failWith :: e -> Iteratee.Iter e a
failWith err = Iteratee.IterFailed err (Iteratee.Chunk BS.empty)

-- | Feeds value bytes to the part's sink; a sink that has already failed ends the form.
feedPart :: Part e a -> BS.ByteString -> IO (Either (e, Iteratee.Stream e) (Part e a))
feedPart part bytes = case part of
    Collecting name it -> classify (Collecting name) <$> Iteratee.feedChunk bytes it
    Sinking name it -> classify (Sinking name) <$> Iteratee.feedChunk bytes it
  where
    classify rebuild it = case it of
        Iteratee.IterFailed err residue -> Left (err, residue)
        other -> Right (rebuild other)

{- | Hands a failed end of stream to the part whose value was being read and
resolves it, so a sink holding a resource (an open file) releases it; the
part's own outcome is then discarded, since the form fails with the stream's
error.
-}
abandonPart :: Part e a -> Iteratee.Stream e -> IO ()
abandonPart part s = case part of
    Collecting _ it -> Monad.void (Iteratee.run (Iteratee.feedStream s it))
    Sinking _ it -> Monad.void (Iteratee.run (Iteratee.feedStream s it))

-- | Records a collected field under the total cap (its name and value both count) and the count cap.
recordField :: FormLimits -> e -> Totals a -> BS.ByteString -> BS.ByteString -> (Totals a -> Iteratee.Iter e b) -> Iteratee.Iter e b
recordField limits tooLarge totals name value k =
    let total' = collectedBytes totals + BS.length name + BS.length value
     in if total' > maxCollectedBytes limits
            then failWith tooLarge
            else countPart limits tooLarge totals (\t -> k t{collectedBytes = total', fields = (name, value) : fields t})

-- | Counts one more part, collected or routed, under the count cap.
countPart :: FormLimits -> e -> Totals a -> (Totals a -> Iteratee.Iter e b) -> Iteratee.Iter e b
countPart limits tooLarge totals k
    | partCount totals + 1 > maxFields limits = failWith tooLarge
    | otherwise = k totals{partCount = partCount totals + 1}

-- | The form's result once the stream has ended.
finished :: Totals a -> Iteratee.Iter e (FormResult a)
finished totals = Iteratee.Done (FormResult (reverse (fields totals)) (reverse (sunk totals))) (Iteratee.Chunk BS.empty)

{- | Percent-decodes a stream of urlencoded value bytes into the given sink, a
block at a time: @+@ becomes a space, @%XX@ becomes the byte, and a malformed
escape passes through verbatim. An escape split across a block boundary is
carried (at most two bytes: a @%@ and one hex digit) into the next block; at end
of stream the carry is flushed verbatim, as the whole-value decoder left a
trailing bare @%@ or truncated escape. The inner sink's end of stream follows
the flush.
-}
decodeFormValueI :: Iteratee.Iter e a -> Iteratee.Iter e a
decodeFormValueI = Iteratee.mapChunksI (Percent.decodeBlock True) id

{- | Normalises line ends in a stream into the given sink: @CRLF@ and a lone @CR@
both become @LF@. A @CR@ at a block end is carried to see whether an @LF@
follows; at end of stream a carried @CR@ is emitted as @LF@.
-}
normaliseNewlinesI :: Iteratee.Iter e a -> Iteratee.Iter e a
normaliseNewlinesI = Iteratee.mapChunksI newlineBlock (\carry -> if BS.null carry then carry else BS.singleton '\n')

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
