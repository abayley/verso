module Verso.LinkFingerprintSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified Data.Map as Map
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.LinkFingerprint as LinkFingerprint

-- | A scratch document tree under build/, reset at the start of each IO test.
root :: FilePath
root = "build/link-fingerprint-spec"

-- | Empties and recreates the scratch tree (no runIO/beforeAll in this Hspec).
freshTree :: IO ()
freshTree = removeTree root >> Directory.createDirectoryIfMissing True root

-- | Recursively removes a path (files via removeFile, directories via the FFI rmdir).
removeTree :: FilePath -> IO ()
removeTree path = do
    isDir <- Directory.doesDirectoryExist path
    if isDir
        then do
            names <- Directory.listDirectory path
            mapM_ (\n -> removeTree (path ++ "/" ++ n)) names
            _ <- FileSystem.removeEmptyDir path
            pure ()
        else do
            exists <- Directory.doesFileExist path
            Monad.when exists (Directory.removeFile path)

-- | Writes a tree-relative file under the scratch root, creating parent directories.
writeAt :: String -> String -> IO ()
writeAt rel content = do
    let full = root ++ "/" ++ rel
    Directory.createDirectoryIfMissing True (parentDir full)
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
            it "given a tree with assets, meta and dot-directories, when it is walked, then only the .md pages are enumerated" $ do
                seedTree
                files <- LinkFingerprint.markdownFiles root
                List.sort (map fst files) `shouldBe` ["a.md", "sub/b.md"]

        describe "fingerprintTree" $ do
            it "given a walked tree, when it is fingerprinted, then every page the walk yields is covered" $ do
                seedTree
                fp <- LinkFingerprint.fingerprintTree root
                Map.keys fp `shouldBe` ["a.md", "sub/b.md"]

            it "given an unchanged tree, when it is fingerprinted again, then the fingerprint is unchanged" $ do
                seedTree
                fp1 <- LinkFingerprint.fingerprintTree root
                fp2 <- LinkFingerprint.fingerprintTree root
                (fp1 == fp2) `shouldBe` True

            it "given an out-of-band edit that keeps the length, when the tree is fingerprinted again, then the fingerprint changes" $ do
                seedTree
                fp1 <- LinkFingerprint.fingerprintTree root
                -- same byte length, different content: only the sub-second mtime moves
                writeAt "sub/b.md" "leaX\n"
                fp2 <- LinkFingerprint.fingerprintTree root
                (fp1 == fp2) `shouldBe` False
