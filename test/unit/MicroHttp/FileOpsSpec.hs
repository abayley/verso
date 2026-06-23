module MicroHttp.FileOpsSpec (spec) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BS
import MicroHttp.FileOps (removeEmptyDir, removeFilePath, renamePath)
import System.Directory (
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removeFile,
 )
import Test.Hspec

-- | A scratch directory under build/, reset at the start of each IO test.
ioDir :: FilePath
ioDir = "build/file-ops-spec"

-- | Empties and recreates the scratch directory (no runIO/beforeAll in this Hspec).
freshDir :: IO ()
freshDir = do
    exists <- doesDirectoryExist ioDir
    when exists removeContents
    createDirectoryIfMissing True ioDir
  where
    removeContents = do
        names <- listDirectory ioDir
        mapM_ removeEntry names
    removeEntry name = do
        let path = ioDir ++ "/" ++ name
        isDir <- doesDirectoryExist path
        if isDir
            then do
                inner <- listDirectory path
                mapM_ (\n -> removeFile (path ++ "/" ++ n)) inner
                _ <- removeEmptyDir path
                pure ()
            else removeFile path

writeText :: FilePath -> String -> IO ()
writeText path = BS.writeFile path . BS.pack

spec :: Spec
spec =
    describe "MicroHttp.FileOps" $ do
        describe "renamePath" $ do
            it "renames an existing file and reports success" $ do
                freshDir
                let from = ioDir ++ "/a.md"
                    to = ioDir ++ "/b.md"
                writeText from "hello"
                ok <- renamePath from to
                ok `shouldBe` True
                fromExists <- doesFileExist from
                toContent <- BS.readFile to
                fromExists `shouldBe` False
                BS.unpack toContent `shouldBe` "hello"

            it "reports failure when the source does not exist" $ do
                freshDir
                ok <- renamePath (ioDir ++ "/missing.md") (ioDir ++ "/x.md")
                ok `shouldBe` False

        describe "removeFilePath" $ do
            it "removes an existing file and reports success" $ do
                freshDir
                let f = ioDir ++ "/gone.md"
                writeText f "x"
                ok <- removeFilePath f
                ok `shouldBe` True
                exists <- doesFileExist f
                exists `shouldBe` False

            it "reports failure when the file is absent" $ do
                freshDir
                ok <- removeFilePath (ioDir ++ "/absent.md")
                ok `shouldBe` False

        describe "removeEmptyDir" $ do
            it "removes an empty directory and reports success" $ do
                freshDir
                let d = ioDir ++ "/sub"
                createDirectoryIfMissing True d
                ok <- removeEmptyDir d
                ok `shouldBe` True
                exists <- doesDirectoryExist d
                exists `shouldBe` False

            it "reports failure for a non-empty directory" $ do
                freshDir
                let d = ioDir ++ "/full"
                createDirectoryIfMissing True d
                writeText (d ++ "/k.md") "x"
                ok <- removeEmptyDir d
                ok `shouldBe` False
