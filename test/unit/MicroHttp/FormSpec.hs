module MicroHttp.FormSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.IORef as IORef
import qualified MicroHttp.Form as Form
import qualified MicroHttp.Iteratee as Iteratee
import Test.Hspec

-- | A domain-free error, as the iteratee tests use.
data TestError = TooLarge | Boom
    deriving (Eq, Show)

spec :: Spec
spec = do
    decoderSpec
    newlineSpec
    parserSpec
    routingSpec

{- | The streaming percent-decoder (RFC-0042): fed in blocks of every size, its
output equals the whole-value oracle, including an escape split across blocks.
-}
decoderSpec :: Spec
decoderSpec =
    describe "MicroHttp.Form decodeFormValueI" $ do
        let check input = do
                results <- mapM (\n -> decodeIn n (bs input)) chunkSizes
                results `shouldBe` replicate (length chunkSizes) (Right (bs (oracleDecode input)))
        it "given plain bytes, when decoded, then they pass through unchanged" $
            check "plain-text_1.2"
        it "given a plus, when decoded, then it is a space" $
            check "a+b++c"
        it "given a percent escape, when decoded, then it is the byte" $
            check "%41%7b%7D"
        it "given an escape split across a block boundary, when decoded, then it is still the byte" $
            check "ab%41cd%42"
        it "given a bare percent at the end and a truncated escape, when decoded, then they pass through verbatim" $
            check "abc%" >> check "abc%a" >> check "a%zzb%"
        it "given a percent-encoded multibyte character split at every boundary, when decoded, then its bytes are verbatim" $
            check "caf%C3%A9!"
        it "given a browser-shaped mixed value, when decoded, then it equals the oracle" $
            check "%23+Heading%0A%0AText+with+caf%C3%A9%2C+100%25+sure%3F%0A%zz+%+%a"
        it "given a value above the megabyte cap, when decoded through a collector, then it completes with the expected length" $ do
            let unit = bs "%41+word%0A" -- decodes to 7 bytes from 11
                input = doubling 17 unit -- 2^17 units, ~1.4MB encoded
                -- fed in socket-sized blocks, as the server does; a block, not the value, bounds each decode
            result <- feedIn 8192 input (Form.decodeFormValueI (Iteratee.readBodyStrict TooLarge 2000000)) >>= Iteratee.run
            fmap BS.length result `shouldBe` Right (7 * 131072)

{- | The streaming newline normaliser: CRLF and lone CR become LF, including a
CR at a block end whose LF arrives in the next block.
-}
newlineSpec :: Spec
newlineSpec =
    describe "MicroHttp.Form normaliseNewlinesI" $ do
        let check input = do
                results <- mapM (\n -> normaliseIn n (bs input)) chunkSizes
                results `shouldBe` replicate (length chunkSizes) (Right (bs (oracleNewlines input)))
        it "given LF-only text, when normalised, then it is unchanged" $
            check "a\nb\n\nc"
        it "given CRLF line ends, when normalised, then each is one LF" $
            check "a\r\nb\r\n\r\nc\r\n"
        it "given lone CRs, when normalised, then each is one LF" $
            check "a\rb\r\rc\r"
        it "given a CR at the very end, when normalised, then it is one LF" $
            check "abc\r"

{- | The part parser with every field collected, fed in blocks of every size,
equals the whole-body oracle for each shape the old parser accepted.
-}
parserSpec :: Spec
parserSpec =
    describe "MicroHttp.Form formI collecting" $ do
        let check input = do
                results <- mapM (\n -> collectIn n (bs input)) chunkSizes
                results `shouldBe` replicate (length chunkSizes) (Right (oracleParse input))
        it "given two fields, when consumed, then both are decoded in order" $
            check "kind=page&title=My+Page"
        it "given an encoded equals sign in a value, when consumed, then only the first splits" $
            check "q=a=b&r=%3D"
        it "given a field with no equals sign, when consumed, then its value is empty" $
            check "flag" >> check "flag&other=1"
        it "given an empty field between separators, when consumed, then it is a field with an empty name" $
            check "a=1&&b=2" >> check "a=1&"
        it "given an empty body, when consumed, then there are no fields" $
            check ""
        it "given percent-encoded names and values, when consumed, then both are decoded" $
            check "na%6De=va%6Cue+1&x%3Dy=z"

-- | Routing a part to its own sink, and the caps on what is collected.
routingSpec :: Spec
routingSpec =
    describe "MicroHttp.Form formI routing and caps" $ do
        it "given a route for one field, when consumed, then that field's raw bytes reach its sink in order and the rest are collected" $ do
            seen <- IORef.newIORef []
            let sink = Iteratee.byteSinkI (\bytes -> IORef.modifyIORef seen (bytes :) >> pure (Right ()))
                route name = if name == bs "markdown" then Form.SinkPart sink else Form.CollectField
            outcome <- Iteratee.strictEnumerator (bs "path=a.md&markdown=%23+H%0A%0Abody&rev=7") (Form.formI limits TooLarge route) >>= Iteratee.run
            fmap fst outcome `shouldBe` Right [(bs "path", bs "a.md"), (bs "rev", bs "7")]
            fmap (map fst . snd) outcome `shouldBe` Right [bs "markdown"]
            raw <- IORef.readIORef seen
            BS.concat (reverse raw) `shouldBe` bs "%23+H%0A%0Abody"
        it "given a routed field split across blocks, when consumed, then the sink sees every byte" $ do
            seen <- IORef.newIORef []
            let sink = Iteratee.byteSinkI (\bytes -> IORef.modifyIORef seen (bytes :) >> pure (Right ()))
                route name = if name == bs "m" then Form.SinkPart sink else Form.CollectField
            outcome <- feedIn 3 (bs "a=1&m=one%20two%20three&z=9") (Form.formI limits TooLarge route) >>= Iteratee.run
            fmap fst outcome `shouldBe` Right [(bs "a", bs "1"), (bs "z", bs "9")]
            raw <- IORef.readIORef seen
            BS.concat (reverse raw) `shouldBe` bs "one%20two%20three"
        it "given a collected field over the per-field cap, when consumed, then it fails with the supplied error" $ do
            outcome <- collectWith limits{Form.maxFieldBytes = 4} (bs "a=12345")
            outcome `shouldBe` Left TooLarge
        it "given a decoded value under the cap whose encoding is over it, when consumed, then it is accepted" $ do
            outcome <- collectWith limits{Form.maxFieldBytes = 4} (bs "a=%41%42%43%44")
            outcome `shouldBe` Right [(bs "a", bs "ABCD")]
        it "given fields whose decoded total exceeds the collected cap, when consumed, then it fails" $ do
            outcome <- collectWith limits{Form.maxCollectedBytes = 5} (bs "a=123&b=456")
            outcome `shouldBe` Left TooLarge
        it "given more fields than the field cap, when consumed, then it fails" $ do
            outcome <- collectWith limits{Form.maxFields = 2} (bs "a=1&b=2&c=3")
            outcome `shouldBe` Left TooLarge
        it "given a routed sink that fails, when consumed, then the form fails with that error" $ do
            let failing = Iteratee.NeedInput (\_ -> Iteratee.IterFailed Boom (Iteratee.Chunk BS.empty))
                route name = if name == bs "m" then Form.SinkPart failing else Form.CollectField
            outcome <- Iteratee.strictEnumerator (bs "a=1&m=xyz&b=2") (Form.formI limits Boom route) >>= Iteratee.run
            fmap fst outcome `shouldBe` Left Boom
        it "given a transport failure mid-body, when consumed, then the failure is surfaced" $ do
            let it0 = Form.formI limits TooLarge (const Form.CollectField) :: Iteratee.Iter TestError ([(BS.ByteString, BS.ByteString)], [(BS.ByteString, ())])
            fed <- Iteratee.feedChunk (bs "a=1&b=") it0
            outcome <- Iteratee.run (feedEnd (Just Boom) fed)
            fmap fst outcome `shouldBe` Left Boom

-- Harness.

limits :: Form.FormLimits
limits = Form.FormLimits{Form.maxFieldBytes = 1024, Form.maxCollectedBytes = 4096, Form.maxFields = 16}

chunkSizes :: [Int]
chunkSizes = [1, 2, 3, 5, 7, 64, 100000]

-- | Feeds the bytes to the iteratee in blocks of the given size, then ends the stream.
feedIn :: Int -> BS.ByteString -> Iteratee.Iter e a -> IO (Iteratee.Iter e a)
feedIn n bytes it0
    | BS.null bytes = pure it0
    | otherwise = do
        let (block, rest) = BS.splitAt n bytes
        it1 <- Iteratee.feedChunk block it0
        feedIn n rest it1

-- | Delivers an end of stream, orderly or failed, to a waiting iteratee.
feedEnd :: Maybe e -> Iteratee.Iter e a -> Iteratee.Iter e a
feedEnd merr it = case it of
    Iteratee.NeedInput k -> k (Iteratee.EndOfStream merr)
    other -> other

decodeIn :: Int -> BS.ByteString -> IO (Either TestError BS.ByteString)
decodeIn n input = feedIn n input (Form.decodeFormValueI (Iteratee.readBodyStrict TooLarge 1000000)) >>= Iteratee.run

normaliseIn :: Int -> BS.ByteString -> IO (Either TestError BS.ByteString)
normaliseIn n input = feedIn n input (Form.normaliseNewlinesI (Iteratee.readBodyStrict TooLarge 1000000)) >>= Iteratee.run

collectIn :: Int -> BS.ByteString -> IO (Either TestError [(BS.ByteString, BS.ByteString)])
collectIn n input = do
    outcome <- feedIn n input (Form.formI limits TooLarge (const Form.CollectField) :: Iteratee.Iter TestError ([(BS.ByteString, BS.ByteString)], [(BS.ByteString, ())])) >>= Iteratee.run
    pure (fmap fst outcome)

collectWith :: Form.FormLimits -> BS.ByteString -> IO (Either TestError [(BS.ByteString, BS.ByteString)])
collectWith lim input = do
    outcome <- Iteratee.strictEnumerator input (Form.formI lim TooLarge (const Form.CollectField) :: Iteratee.Iter TestError ([(BS.ByteString, BS.ByteString)], [(BS.ByteString, ())])) >>= Iteratee.run
    pure (fmap fst outcome)

-- | Doubles a chunk n times by appending, so a large fixture is built without a long list.
doubling :: Int -> BS.ByteString -> BS.ByteString
doubling 0 x = x
doubling n x = doubling (n - 1) (BS.append x x)

-- Oracles: the whole-value semantics the streaming forms must reproduce, written
-- over String so they do not depend on the code under test.

oracleDecode :: String -> String
oracleDecode [] = []
oracleDecode ('+' : rest) = ' ' : oracleDecode rest
oracleDecode ('%' : a : b : rest)
    | Char.isHexDigit a && Char.isHexDigit b = Char.chr (Char.digitToInt a * 16 + Char.digitToInt b) : oracleDecode rest
    | otherwise = '%' : a : b : oracleDecode rest
oracleDecode (c : rest) = c : oracleDecode rest

oracleNewlines :: String -> String
oracleNewlines [] = []
oracleNewlines ('\r' : '\n' : rest) = '\n' : oracleNewlines rest
oracleNewlines ('\r' : rest) = '\n' : oracleNewlines rest
oracleNewlines (c : rest) = c : oracleNewlines rest

oracleParse :: String -> [(BS.ByteString, BS.ByteString)]
oracleParse [] = []
oracleParse body = map field (splitOn '&' body)
  where
    field f = case break (== '=') f of
        (k, '=' : v) -> (bs (oracleDecode k), bs (oracleDecode v))
        (k, _) -> (bs (oracleDecode k), BS.empty)
    splitOn sep s = case break (== sep) s of
        (before, _ : after) -> before : splitOn sep after
        (before, []) -> [before]

bs :: String -> BS.ByteString
bs = BS.pack
