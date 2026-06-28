module Verso.LinkFingerprintSpec (spec) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BS
import Data.List (sort)
import qualified Data.Map as Map
import MicroHttp.FileSystem (removeEmptyDir)
import System.Directory (
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removeFile,
 )
import Test.Hspec
import Verso.LinkFingerprint (fingerprintTree, markdownFiles)

-- | A scratch document tree under build/, reset at the start of each IO test.
root :: FilePath
root = "build/link-fingerprint-spec"

-- | Empties and recreates the scratch tree (no runIO/beforeAll in this Hspec).
freshTree :: IO ()
freshTree = removeTree root >> createDirectoryIfMissing True root

-- | Recursively removes a path (files via removeFile, directories via the FFI rmdir).
removeTree :: FilePath -> IO ()
removeTree path = do
    isDir <- doesDirectoryExist path
    if isDir
        then do
            names <- listDirectory path
            mapM_ (\n -> removeTree (path ++ "/" ++ n)) names
            _ <- removeEmptyDir path
            pure ()
        else do
            exists <- doesFileExist path
            when exists (removeFile path)

-- | Writes a tree-relative file under the scratch root, creating parent directories.
writeAt :: String -> String -> IO ()
writeAt rel content = do
    let full = root ++ "/" ++ rel
    createDirectoryIfMissing True (parentDir full)
    BS.writeFile full (BS.pack content)
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

-- | A small tree with pages plus assets/meta/dot entries the walk must skip.
seedTree :: IO ()
seedTree = do
    freshTree
    writeAt "a.md" "[B](./sub/b.md)\n"
    writeAt "sub/b.md" "leaf\n"
    writeAt "assets/x.png" "binary"
    writeAt "assets/note.md" "asset-adjacent markdown, skipped\n"
    writeAt "meta/m.md" "sidecar markdown, skipped\n"
    writeAt ".hidden/c.md" "hidden markdown, skipped\n"

spec :: Spec
spec =
    describe "Verso.LinkFingerprint" $ do
        describe "markdownFiles" $ do
            it "enumerates only the .md pages, skipping assets, meta, and dot-dirs" $ do
                seedTree
                files <- markdownFiles root
                sort (map fst files) `shouldBe` ["a.md", "sub/b.md"]

        describe "fingerprintTree" $ do
            it "fingerprints every page the walk yields" $ do
                seedTree
                fp <- fingerprintTree root
                Map.keys fp `shouldBe` ["a.md", "sub/b.md"]

            it "is unchanged when the tree is unchanged" $ do
                seedTree
                fp1 <- fingerprintTree root
                fp2 <- fingerprintTree root
                (fp1 == fp2) `shouldBe` True

            it "changes on an out-of-band equal-length edit" $ do
                seedTree
                fp1 <- fingerprintTree root
                -- same byte length, different content: only the sub-second mtime moves
                writeAt "sub/b.md" "leaX\n"
                fp2 <- fingerprintTree root
                (fp1 == fp2) `shouldBe` False
