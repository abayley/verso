module MicroHttp.FileSystemSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory
import Test.Hspec

-- | A scratch directory under build/, reset at the start of each IO test.
ioDir :: FilePath
ioDir = "build/file-ops-spec"

-- | Empties and recreates the scratch directory (no runIO/beforeAll in this Hspec).
freshDir :: IO ()
freshDir = do
    exists <- Directory.doesDirectoryExist ioDir
    Monad.when exists removeContents
    Directory.createDirectoryIfMissing True ioDir
  where
    removeContents = do
        names <- Directory.listDirectory ioDir
        mapM_ removeEntry names
    removeEntry name = do
        let path = ioDir ++ "/" ++ name
        isDir <- Directory.doesDirectoryExist path
        if isDir
            then do
                inner <- Directory.listDirectory path
                mapM_ (\n -> Directory.removeFile (path ++ "/" ++ n)) inner
                _ <- FileSystem.removeEmptyDir path
                pure ()
            else Directory.removeFile path

writeText :: FilePath -> String -> IO ()
writeText path = BS.writeFile path . BS.pack

spec :: Spec
spec =
    describe "MicroHttp.FileSystem" $ do
        describe "renamePath" $ do
            it "renames an existing file and reports success" $ do
                freshDir
                let from = ioDir ++ "/a.md"
                    to = ioDir ++ "/b.md"
                writeText from "hello"
                ok <- FileSystem.renamePath from to
                ok `shouldBe` True
                fromExists <- Directory.doesFileExist from
                toContent <- BS.readFile to
                fromExists `shouldBe` False
                BS.unpack toContent `shouldBe` "hello"

            it "reports failure when the source does not exist" $ do
                freshDir
                ok <- FileSystem.renamePath (ioDir ++ "/missing.md") (ioDir ++ "/x.md")
                ok `shouldBe` False

        describe "removeFilePath" $ do
            it "removes an existing file and reports success" $ do
                freshDir
                let f = ioDir ++ "/gone.md"
                writeText f "x"
                ok <- FileSystem.removeFilePath f
                ok `shouldBe` True
                exists <- Directory.doesFileExist f
                exists `shouldBe` False

            it "reports failure when the file is absent" $ do
                freshDir
                ok <- FileSystem.removeFilePath (ioDir ++ "/absent.md")
                ok `shouldBe` False

        describe "removeEmptyDir" $ do
            it "removes an empty directory and reports success" $ do
                freshDir
                let d = ioDir ++ "/sub"
                Directory.createDirectoryIfMissing True d
                ok <- FileSystem.removeEmptyDir d
                ok `shouldBe` True
                exists <- Directory.doesDirectoryExist d
                exists `shouldBe` False

            it "reports failure for a non-empty directory" $ do
                freshDir
                let d = ioDir ++ "/full"
                Directory.createDirectoryIfMissing True d
                writeText (d ++ "/k.md") "x"
                ok <- FileSystem.removeEmptyDir d
                ok `shouldBe` False

        describe "fileStat" $ do
            it "reports a file's byte size" $ do
                freshDir
                let f = ioDir ++ "/sized.md"
                writeText f "hello"
                st <- FileSystem.fileStat f
                fmap FileSystem.fsSize st `shouldBe` Just 5

            it "moves the modification time on an equal-length edit (sub-second)" $ do
                freshDir
                let f = ioDir ++ "/edited.md"
                writeText f "aaaa"
                before <- FileSystem.fileStat f
                writeText f "bbbb"
                after <- FileSystem.fileStat f
                -- size is unchanged, so only the sub-second mtime distinguishes the edit
                fmap FileSystem.fsSize before `shouldBe` fmap FileSystem.fsSize after
                (before == after) `shouldBe` False

            it "reports Nothing for a missing path" $ do
                freshDir
                FileSystem.fileStat (ioDir ++ "/absent.md") `shouldReturn` Nothing
