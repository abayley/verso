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
            it "given an existing file, when it is renamed, then it moves and success is reported" $ do
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

            it "given a missing source, when a rename is attempted, then ENOENT is reported" $ do
                freshDir
                outcome <- FileSystem.renamePath (ioDir ++ "/missing.md") (ioDir ++ "/x.md")
                outcome `shouldBe` Left (FileSystem.Errno 2)

        describe "removeFilePath" $ do
            it "given an existing file, when it is removed, then it is gone and success is reported" $ do
                freshDir
                let f = ioDir ++ "/gone.md"
                writeText f "x"
                outcome <- FileSystem.removeFilePath f
                outcome `shouldBe` Right ()
                exists <- Directory.doesFileExist f
                exists `shouldBe` False

            it "given an absent file, when a remove is attempted, then ENOENT is reported" $ do
                freshDir
                outcome <- FileSystem.removeFilePath (ioDir ++ "/absent.md")
                outcome `shouldBe` Left (FileSystem.Errno 2)

        describe "removeEmptyDir" $ do
            it "given an empty directory, when it is removed, then it is gone and success is reported" $ do
                freshDir
                let d = ioDir ++ "/sub"
                Directory.createDirectoryIfMissing True d
                outcome <- FileSystem.removeEmptyDir d
                outcome `shouldBe` Right ()
                exists <- Directory.doesDirectoryExist d
                exists `shouldBe` False

            it "given a non-empty directory, when a remove is attempted, then ENOTEMPTY is reported" $ do
                freshDir
                let d = ioDir ++ "/full"
                Directory.createDirectoryIfMissing True d
                writeText (d ++ "/k.md") "x"
                outcome <- FileSystem.removeEmptyDir d
                -- 66 is macOS ENOTEMPTY; the module is macOS-specific (ADR-067)
                outcome `shouldBe` Left (FileSystem.Errno 66)

        describe "fileStat" $ do
            it "given a file, when it is stat-ed, then its byte size is reported" $ do
                freshDir
                let f = ioDir ++ "/sized.md"
                writeText f "hello"
                st <- FileSystem.fileStat f
                fmap FileSystem.fsSize st `shouldBe` Right 5

            it "given an edit that keeps the length, when the file is stat-ed again, then the modification time has moved" $ do
                freshDir
                let f = ioDir ++ "/edited.md"
                writeText f "aaaa"
                before <- FileSystem.fileStat f
                writeText f "bbbb"
                after <- FileSystem.fileStat f
                -- size is unchanged, so only the sub-second mtime distinguishes the edit
                fmap FileSystem.fsSize before `shouldBe` fmap FileSystem.fsSize after
                (before == after) `shouldBe` False

            it "given a missing path, when it is stat-ed, then ENOENT is reported" $ do
                freshDir
                FileSystem.fileStat (ioDir ++ "/absent.md") `shouldReturn` Left (FileSystem.Errno 2)

            it "given a path inside an unsearchable directory, when it is stat-ed, then EACCES is reported rather than ENOENT" $ do
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
            it "given each errno, when tested for does-not-exist, then only ENOENT matches" $ do
                FileSystem.isDoesNotExist (FileSystem.Errno 2) `shouldBe` True
                FileSystem.isDoesNotExist (FileSystem.Errno 13) `shouldBe` False
                FileSystem.isDoesNotExist (FileSystem.Errno 66) `shouldBe` False

        describe "readFileStrict" $ do
            it "given a file, when read, then the whole content is returned" $ do
                freshDir
                let f = ioDir ++ "/strict.txt"
                writeFile f "line one\nline two\n"
                FileSystem.readFileStrict f `shouldReturn` "line one\nline two\n"

            it "given a strict read, when the same path is rewritten immediately, then the write succeeds" $ do
                -- GHC's lazy readFile holds a read lock until the string is forced,
                -- so an unforced read followed by writeFile throws "resource busy"
                freshDir
                let f = ioDir ++ "/rewrite.txt"
                writeFile f "before"
                text <- FileSystem.readFileStrict f
                writeFile f "after"
                text `shouldBe` "before"
                FileSystem.readFileStrict f `shouldReturn` "after"
