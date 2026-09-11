module MicroHttp.StreamSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import Test.Hspec

-- | A scratch directory under build/, reset at the start of each IO test.
scratch :: FilePath
scratch = "build/stream-spec"

resetScratch :: IO ()
resetScratch = do
    exists <- Directory.doesDirectoryExist scratch
    Monad.when exists $ do
        names <- Directory.listDirectory scratch
        mapM_ (\name -> Directory.removeFile (scratch ++ "/" ++ name)) names
    Directory.createDirectoryIfMissing True scratch

tooLarge :: Stream.StreamError
tooLarge = Stream.StreamParseError Parse.BodyTooLarge

spec :: Spec
spec = do
    fileSinkSpec
    filesEqualSpec

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
