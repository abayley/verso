module MicroHttp.StreamSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import Test.Hspec
import qualified TestSupport.Scratch as Scratch

-- | A scratch directory under build/, reset at the start of each IO test.
scratch :: FilePath
scratch = "build/stream-spec"

resetScratch :: IO ()
resetScratch = Scratch.resetScratchDir scratch

tooLarge :: Stream.StreamError
tooLarge = Stream.StreamParseError Parse.BodyTooLarge

spec :: Spec
spec = do
    fileSinkSpec
    filesEqualSpec
    escapedBodySpec
    fileContainsSpec
    writeFileLinesSpec
    foldFileLinesSpec

{- | The streamed line reader (RFC-0040): folding over a file's lines block by
block reproduces 'Prelude.lines' exactly -- including blank lines, a final line
with no trailing newline, and a line spanning a block boundary -- without holding
the file whole.
-}
foldFileLinesSpec :: Spec
foldFileLinesSpec =
    describe "MicroHttp.Stream foldFileLines" $ do
        let collect path = do
                outcome <- Stream.foldFileLines (\acc l -> pure (l : acc)) [] path
                pure (fmap reverse outcome)
            expected content = map BS.pack (lines (BS.unpack content))
            check content = do
                resetScratch
                BS.writeFile docPath content
                got <- collect docPath
                got `shouldBe` Right (expected content)
        it "given plain lines with a trailing newline, when folded, then it matches lines" $
            check (bs "alpha\nbeta\ngamma\n")
        it "given no trailing newline, when folded, then the final line is still folded" $
            check (bs "alpha\nbeta\ngamma")
        it "given blank lines, when folded, then they are preserved as empty lines" $
            check (bs "a\n\n\nb\n")
        it "given an empty file, when folded, then no lines are folded" $
            check (bs "")
        it "given a line spanning a 64KB block boundary, when folded, then it is read whole" $
            check (BS.concat [BS.replicate (65536 - 3) 'x', bs "LINE-ACROSS-BOUNDARY\ntail\n"])
        it "given a missing file, when folded, then the failure is reported" $ do
            resetScratch
            outcome <- Stream.foldFileLines (\acc l -> pure (l : acc)) [] (scratch ++ "/absent")
            either (const True) (const False) outcome `shouldBe` True

{- | The streamed line writer (RFC-0040): writing lines one at a time is
byte-identical to packing @unlines@ of them whole, so a large line-oriented file
(the persisted link index) is written without a whole-String or whole-file spike.
-}
writeFileLinesSpec :: Spec
writeFileLinesSpec =
    describe "MicroHttp.Stream writeFileLines" $ do
        it "given several lines, when written, then the file equals BS.pack (unlines them)" $ do
            resetScratch
            let ls = [bs "E\tsec/page.md\ttarget.md", bs "E\tempty.md", bs "F\ta.md\t1\t2\t3"]
            Stream.writeFileLines docPath ls >>= (`shouldBe` Right ())
            written <- BS.readFile docPath
            written `shouldBe` BS.pack (unlines (map BS.unpack ls))
        it "given no lines, when written, then the file is empty" $ do
            resetScratch
            Stream.writeFileLines docPath [] >>= (`shouldBe` Right ())
            BS.readFile docPath >>= (`shouldBe` BS.empty)
        it "given an unwritable path, when written, then the failure is reported" $ do
            resetScratch
            outcome <- Stream.writeFileLines (scratch ++ "/no-such-dir/f") [bs "x"]
            either (const True) (const False) outcome `shouldBe` True

{- | The streamed substring pre-filter (RFC-0040): a file is scanned in blocks for
a needle without being held whole, and a match straddling a block boundary is
still found because each block carries the previous block's tail.
-}
fileContainsSpec :: Spec
fileContainsSpec =
    describe "MicroHttp.Stream fileContains" $ do
        it "given a needle present within a block, when scanned, then it is found" $ do
            resetScratch
            BS.writeFile docPath (bs "the quick brown fox")
            Stream.fileContains (bs "brown") docPath >>= (`shouldBe` Right True)
        it "given a needle absent, when scanned, then it is not found" $ do
            resetScratch
            BS.writeFile docPath (bs "the quick brown fox")
            Stream.fileContains (bs "purple") docPath >>= (`shouldBe` Right False)
        it "given a needle straddling a 64KB block boundary, when scanned, then it is still found" $ do
            resetScratch
            BS.writeFile docPath (BS.concat [BS.replicate (65536 - 3) 'x', bs "NEEDLE", bs "yyy"])
            Stream.fileContains (bs "NEEDLE") docPath >>= (`shouldBe` Right True)
        it "given a needle only at the very end past a boundary, when scanned, then it is found" $ do
            resetScratch
            BS.writeFile docPath (BS.concat [BS.replicate 70000 'x', bs "TAILWORD"])
            Stream.fileContains (bs "TAILWORD") docPath >>= (`shouldBe` Right True)
        it "given an empty needle, when scanned, then it is found in any readable file" $ do
            resetScratch
            BS.writeFile docPath (bs "anything")
            Stream.fileContains (bs "") docPath >>= (`shouldBe` Right True)
        it "given a missing file, when scanned, then the failure is reported rather than a verdict" $ do
            resetScratch
            outcome <- Stream.fileContains (bs "x") (scratch ++ "/absent.md")
            either (const True) (const False) outcome `shouldBe` True

{- | The escaped document producer and its length count (RFC-0040). The escaper
is byte-wise, so escaping a document a block at a time must equal escaping it
whole at every block size, and the folded length must equal the whole escaped
length; these fix that as tests, with specials landing at and across boundaries.
-}
escapedBodySpec :: Spec
escapedBodySpec =
    describe "MicroHttp.Stream escaped document body" $ do
        it "given a file whose bytes escape, when its escaped length is folded in small blocks, then it equals the whole escaping length" $ do
            resetScratch
            BS.writeFile docPath boundaryContent
            wholeLen <- BS.length <$> Html.escapeBlockBytes boundaryContent
            folded <- mapM (\n -> Stream.foldFileBlocks n countEscaped 0 docPath) blockSizes
            folded `shouldBe` replicate (length blockSizes) (Right wholeLen)
        it "given before and after around a file, when streamed as a transformed body, then it equals before, the whole escaping, then after at every block size" $ do
            resetScratch
            BS.writeFile docPath boundaryContent
            whole <- Html.escapeBlockBytes boundaryContent
            let expected = BS.concat [before, whole, after]
            results <- mapM (collectTransformedBody before after) blockSizes
            results `shouldBe` replicate (length blockSizes) (Right expected)
        it "given an empty file, when streamed as a transformed body, then only before and after are emitted" $ do
            resetScratch
            BS.writeFile docPath (bs "")
            result <- collectTransformedBody before after 4
            result `shouldBe` Right (BS.concat [before, after])
        it "given empty before and after, when streamed as a transformed body, then only the whole escaping is emitted" $ do
            resetScratch
            BS.writeFile docPath boundaryContent
            whole <- Html.escapeBlockBytes boundaryContent
            result <- collectTransformedBody (bs "") (bs "") 3
            result `shouldBe` Right whole
        it "given a temp capture, when streamed as a transformed body to completion, then the bytes match and the file is removed" $ do
            resetScratch
            BS.writeFile docPath boundaryContent
            whole <- Html.escapeBlockBytes boundaryContent
            final <- Stream.transformedTempFileBody 4 before Html.escapeBlockBytes docPath after (Iteratee.readBodyStrict tooLarge 1000000)
            result <- Iteratee.run final
            result `shouldBe` Right (BS.concat [before, whole, after])
            Directory.doesFileExist docPath `shouldReturn` False
        it "given a temp capture, when the consumer stops early, then the file is still removed" $ do
            resetScratch
            BS.writeFile docPath boundaryContent
            final <- Stream.transformedTempFileBody 4 before Html.escapeBlockBytes docPath after (Iteratee.takeN 3 (Iteratee.readBodyStrict tooLarge 1000000))
            result <- Iteratee.run final
            result `shouldBe` Right (BS.take 3 before)
            Directory.doesFileExist docPath `shouldReturn` False
        it "given a temp path that does not exist, when streamed, then the consumer sees the source error" $ do
            resetScratch
            final <- Stream.transformedTempFileBody 4 before Html.escapeBlockBytes (scratch ++ "/absent") after (Iteratee.readBodyStrict tooLarge 1000000)
            result <- Iteratee.run final
            result `shouldBe` Left (Stream.StreamSourceError ("cannot open file: " ++ scratch ++ "/absent"))

-- | Content with the escaped bytes at, adjacent to, and across 1-8 byte boundaries.
boundaryContent :: BS.ByteString
boundaryContent = BS.pack "<>&\"'a<>&\"'bc<>&\"'def<>&\"'ghij\xc3\xa9<>&\"'"

-- | The block sizes exercised: below, at, and above the special runs.
blockSizes :: [Int]
blockSizes = [1, 2, 3, 4, 7, 8, 1000]

-- | Sums a block's escaped length onto an accumulator, for 'Stream.foldFileBlocks'.
countEscaped :: Int -> BS.ByteString -> IO Int
countEscaped acc block = (acc +) <$> Html.escapedLength block

-- | Runs the escaped body producer into a collecting consumer, returning the bytes.
collectTransformedBody :: BS.ByteString -> BS.ByteString -> Int -> IO (Either Stream.StreamError BS.ByteString)
collectTransformedBody pre post blockSize = do
    final <- Stream.transformedFileBody blockSize pre Html.escapeBlockBytes docPath post (Iteratee.readBodyStrict tooLarge 1000000)
    Iteratee.run final

before :: BS.ByteString
before = BS.pack "<<BEFORE-SHELL>>"

after :: BS.ByteString
after = BS.pack "<<AFTER-SHELL>>"

docPath :: FilePath
docPath = scratch ++ "/doc.md"

filesEqualSpec :: Spec
filesEqualSpec =
    describe "MicroHttp.Stream streamed comparison" $ do
        it "given two files with identical bytes, when compared, then they are equal" $ do
            resetScratch
            BS.writeFile (scratch ++ "/a") (bs "same content here")
            BS.writeFile (scratch ++ "/b") (bs "same content here")
            Stream.filesEqual (scratch ++ "/a") (scratch ++ "/b") >>= (`shouldBe` Right True)
        it "given two files of the same size that differ in one byte, when compared, then they are not equal" $ do
            resetScratch
            BS.writeFile (scratch ++ "/a") (bs "same content here")
            BS.writeFile (scratch ++ "/b") (bs "same content hero")
            Stream.filesEqual (scratch ++ "/a") (scratch ++ "/b") >>= (`shouldBe` Right False)
        it "given two files of different sizes, when compared, then they are not equal" $ do
            resetScratch
            BS.writeFile (scratch ++ "/a") (bs "short")
            BS.writeFile (scratch ++ "/b") (bs "longer than short")
            Stream.filesEqual (scratch ++ "/a") (scratch ++ "/b") >>= (`shouldBe` Right False)
        it "given a missing file, when compared, then the failure is reported rather than a verdict" $ do
            resetScratch
            BS.writeFile (scratch ++ "/a") (bs "present")
            outcome <- Stream.filesEqual (scratch ++ "/a") (scratch ++ "/absent")
            either (const True) (const False) outcome `shouldBe` True

fileSinkSpec :: Spec
fileSinkSpec =
    describe "MicroHttp.Stream file sink" $ do
        it "given a body arriving in several chunks, when sunk to a file, then the file holds the bytes and the count is returned" $ do
            resetScratch
            let path = scratch ++ "/body.bin"
            outcome <- Iteratee.run (feed [bs "abc", bs "def", bs "", bs "ghi"] (Stream.fileSinkI 100 tooLarge path))
            outcome `shouldBe` Right 9
            stored <- BS.readFile path
            stored `shouldBe` bs "abcdefghi"
        it "given a body over the cap, when sunk to a file, then it fails with the cap error and leaves no file behind" $ do
            resetScratch
            let path = scratch ++ "/over.bin"
            outcome <- Iteratee.run (feed [bs "12345", bs "67890", bs "x"] (Stream.fileSinkI 10 tooLarge path))
            outcome `shouldBe` Left tooLarge
            left <- Directory.doesFileExist path
            left `shouldBe` False
        it "given a body exactly at the cap, when sunk to a file, then it is accepted in full" $ do
            resetScratch
            let path = scratch ++ "/exact.bin"
            outcome <- Iteratee.run (feed [bs "12345", bs "67890"] (Stream.fileSinkI 10 tooLarge path))
            outcome `shouldBe` Right 10
        it "given a transport failure mid-body, when sunk to a file, then the failure is surfaced and the partial file is removed" $ do
            resetScratch
            let path = scratch ++ "/broken.bin"
                readError = Stream.StreamTimeout
            outcome <- Iteratee.run (failAfter [bs "partial"] readError (Stream.fileSinkI 100 tooLarge path))
            outcome `shouldBe` Left readError
            left <- Directory.doesFileExist path
            left `shouldBe` False

-- | Feeds chunks, then ends the stream with a transport error.
failAfter :: [BS.ByteString] -> e -> Iteratee.Iter e a -> Iteratee.Iter e a
failAfter [] err it = case it of
    Iteratee.NeedInput k -> k (Iteratee.EndOfStream (Just err))
    Iteratee.IterM m -> Iteratee.IterM (fmap (failAfter [] err) m)
    other -> other
failAfter (c : cs) err it = case it of
    Iteratee.NeedInput k -> failAfter cs err (k (Iteratee.Chunk c))
    Iteratee.IterM m -> Iteratee.IterM (fmap (failAfter (c : cs) err) m)
    other -> other

-- | Feeds chunks to an iteratee the way an enumerator does, then end of stream.
feed :: [BS.ByteString] -> Iteratee.Iter e a -> Iteratee.Iter e a
feed [] it = case it of
    Iteratee.NeedInput k -> k (Iteratee.EndOfStream Nothing)
    other -> other
feed (c : cs) it = case it of
    Iteratee.NeedInput k -> feed cs (k (Iteratee.Chunk c))
    Iteratee.IterM m -> Iteratee.IterM (fmap (feed (c : cs)) m)
    other -> other

bs :: String -> BS.ByteString
bs = BS.pack
