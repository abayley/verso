module MicroHttp.FileSystemSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import Test.Hspec

-- | A scratch directory under build/, reset at the start of each IO test.
ioDir :: FilePath
ioDir = "build/file-ops-spec"

-- | Empties and recreates the scratch directory (no runIO/beforeAll in this Hspec).
freshDir :: IO ()
freshDir = do
    exists <- Directory.doesDirectoryExist ioDir
    -- restore permissions first: the EACCES test locks a subdirectory, and a crash
    -- between its chmods would otherwise leave the scratch tree unlistable
    Monad.when exists (Monad.void (Process.runProcess "chmod" ["-R", "u+rwx", ioDir] Nothing Nothing))
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
                outcome <- FileSystem.renamePath from to
                outcome `shouldBe` Right ()
                fromExists <- Directory.doesFileExist from
                toContent <- BS.readFile to
                fromExists `shouldBe` False
                BS.unpack toContent `shouldBe` "hello"

            it "reports ENOENT when the source does not exist" $ do
                freshDir
                outcome <- FileSystem.renamePath (ioDir ++ "/missing.md") (ioDir ++ "/x.md")
                outcome `shouldBe` Left (FileSystem.Errno 2)

        describe "removeFilePath" $ do
            it "removes an existing file and reports success" $ do
                freshDir
                let f = ioDir ++ "/gone.md"
                writeText f "x"
                outcome <- FileSystem.removeFilePath f
                outcome `shouldBe` Right ()
                exists <- Directory.doesFileExist f
                exists `shouldBe` False

            it "reports ENOENT when the file is absent" $ do
                freshDir
                outcome <- FileSystem.removeFilePath (ioDir ++ "/absent.md")
                outcome `shouldBe` Left (FileSystem.Errno 2)

        describe "removeEmptyDir" $ do
            it "removes an empty directory and reports success" $ do
                freshDir
                let d = ioDir ++ "/sub"
                Directory.createDirectoryIfMissing True d
                outcome <- FileSystem.removeEmptyDir d
                outcome `shouldBe` Right ()
                exists <- Directory.doesDirectoryExist d
                exists `shouldBe` False

            it "reports ENOTEMPTY for a non-empty directory" $ do
                freshDir
                let d = ioDir ++ "/full"
                Directory.createDirectoryIfMissing True d
                writeText (d ++ "/k.md") "x"
                outcome <- FileSystem.removeEmptyDir d
                -- 66 is macOS ENOTEMPTY; the module is macOS-specific (ADR-067)
                outcome `shouldBe` Left (FileSystem.Errno 66)

        describe "fileStat" $ do
            it "reports a file's byte size" $ do
                freshDir
                let f = ioDir ++ "/sized.md"
                writeText f "hello"
                st <- FileSystem.fileStat f
                fmap FileSystem.fsSize st `shouldBe` Right 5

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

            it "reports ENOENT for a missing path" $ do
                freshDir
                FileSystem.fileStat (ioDir ++ "/absent.md") `shouldReturn` Left (FileSystem.Errno 2)

            it "reports EACCES (not ENOENT) for a path inside an unsearchable directory" $ do
                freshDir
                let d = ioDir ++ "/locked"
                    f = d ++ "/secret.md"
                Directory.createDirectoryIfMissing True d
                writeText f "x"
                _ <- Process.runProcess "chmod" ["000", d] Nothing Nothing
                outcome <- FileSystem.fileStat f
                _ <- Process.runProcess "chmod" ["755", d] Nothing Nothing
                outcome `shouldBe` Left (FileSystem.Errno 13)

        describe "isDoesNotExist" $ do
            it "is True only for ENOENT" $ do
                FileSystem.isDoesNotExist (FileSystem.Errno 2) `shouldBe` True
                FileSystem.isDoesNotExist (FileSystem.Errno 13) `shouldBe` False
                FileSystem.isDoesNotExist (FileSystem.Errno 66) `shouldBe` False
