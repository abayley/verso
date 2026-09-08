module Verso.LinkIndexStoreSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.LinkIndex as LinkIndex
import qualified Verso.LinkIndexStore as LinkIndexStore

-- | A scratch document tree under build/, reset at the start of each IO test.
root :: FilePath
root = "build/link-index-store-spec"

-- | The persisted index file, kept outside the tree root so the walk never sees it.
indexPath :: FilePath
indexPath = "build/link-index-store-spec.idx"

freshTree :: IO ()
freshTree = do
    removeTree root
    Directory.createDirectoryIfMissing True root
    exists <- Directory.doesFileExist indexPath
    Monad.when exists (Directory.removeFile indexPath)

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

writeAt :: String -> String -> IO ()
writeAt rel content = do
    let full = root ++ "/" ++ rel
    Directory.createDirectoryIfMissing True (parentDir full)
    BS.writeFile full (BS.pack content)
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

removeAt :: String -> IO ()
removeAt rel = Directory.removeFile (root ++ "/" ++ rel)

spec :: Spec
spec =
    describe "Verso.LinkIndexStore" $ do
        it "given a tree of pages, when the index is built, then referrer queries are answered without walking it" $ do
            freshTree
            writeAt "a.md" "[B](./b.md) [C](./c.md)\n"
            writeAt "b.md" "leaf b\n"
            writeAt "c.md" "leaf c\n"
            store <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store
            ix <- LinkIndexStore.currentIndex store
            List.sort (LinkIndex.inboundOf "b.md" ix) `shouldBe` ["a.md"]
            List.sort (LinkIndex.inboundOf "c.md" ix) `shouldBe` ["a.md"]

        it "given a persisted index, when it is reloaded, then it is reused, and rebuilt when its fingerprint is stale" $ do
            freshTree
            writeAt "a.md" "[B](./b.md)\n"
            writeAt "b.md" "leaf b\n"
            store1 <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store1 -- builds and persists
            Directory.doesFileExist indexPath `shouldReturn` True
            -- a fresh store loads the persisted index (tree unchanged -> fingerprint matches)
            store2 <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store2
            ix2 <- LinkIndexStore.currentIndex store2
            List.sort (LinkIndex.inboundOf "b.md" ix2) `shouldBe` ["a.md"]
            -- change the tree out-of-band, then a fresh open detects the stale fingerprint and rebuilds
            writeAt "a.md" "[C](./c.md)\n"
            writeAt "c.md" "leaf c\n"
            store3 <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store3
            ix3 <- LinkIndexStore.currentIndex store3
            LinkIndex.inboundOf "b.md" ix3 `shouldBe` []
            List.sort (LinkIndex.inboundOf "c.md" ix3) `shouldBe` ["a.md"]

        it "given a modified, an added and a removed page, when the changes are applied, then the index is patched without a walk" $ do
            freshTree
            writeAt "a.md" "[B](./b.md)\n"
            writeAt "b.md" "leaf b\n"
            writeAt "c.md" "leaf c\n"
            store <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store
            -- modify a (now links c), add d (links b), remove c
            writeAt "a.md" "[C](./c.md)\n"
            writeAt "d.md" "[B](./b.md)\n"
            removeAt "c.md"
            LinkIndexStore.applyChanges root ["a.md", "d.md", "c.md"] store
            ix <- LinkIndexStore.currentIndex store
            List.sort (LinkIndex.inboundOf "b.md" ix) `shouldBe` ["d.md"]
            List.sort (LinkIndex.inboundOf "c.md" ix) `shouldBe` ["a.md"]
            LinkIndex.outboundOf "c.md" ix `shouldBe` []

        it "given a moved subtree, when the index is relocated, then its keys and targets follow" $ do
            freshTree
            writeAt "index.md" "[Guide](./guide/index.md)\n"
            writeAt "guide/index.md" "# Guide\n"
            writeAt "guide/page.md" "up [Home](../index.md)\n"
            store <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store
            LinkIndexStore.relocateInIndex "guide" "manual" store
            ix <- LinkIndexStore.currentIndex store
            -- the subtree pages are re-keyed
            LinkIndex.outboundOf "guide/page.md" ix `shouldBe` []
            List.sort (LinkIndex.outboundOf "manual/page.md" ix) `shouldBe` ["index.md"]
            -- the inbound to index.md now comes from the relocated page
            List.sort (LinkIndex.inboundOf "index.md" ix) `shouldBe` ["manual/page.md"]

        it "given a deleted section, when its subtree is removed, then every page under it leaves the index" $ do
            freshTree
            writeAt "index.md" "root\n"
            writeAt "sec/index.md" "# Sec\n"
            writeAt "sec/a.md" "[Home](../index.md)\n"
            store <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store
            LinkIndexStore.removeSubtreeInIndex "sec" store
            ix <- LinkIndexStore.currentIndex store
            LinkIndex.outboundOf "sec/a.md" ix `shouldBe` []
            LinkIndex.inboundOf "index.md" ix `shouldBe` []

        it "given a restored subtree, when it is added, then its pages are read back into the index" $ do
            freshTree
            writeAt "index.md" "root\n"
            store <- LinkIndexStore.newLinkIndexStore
            LinkIndexStore.openLinkIndex root indexPath store
            -- restore a section out-of-band, then add it to the index
            writeAt "sec/index.md" "# Sec\n"
            writeAt "sec/a.md" "[Home](../index.md)\n"
            LinkIndexStore.addSubtreeToIndex root "sec" store
            ix <- LinkIndexStore.currentIndex store
            List.sort (LinkIndex.outboundOf "sec/a.md" ix) `shouldBe` ["index.md"]
            List.sort (LinkIndex.inboundOf "index.md" ix) `shouldBe` ["sec/a.md"]
