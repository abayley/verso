module MicroHttp.LinkIndexStoreSpec (spec) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BS
import Data.List (sort)
import MicroHttp.FileOps (removeEmptyDir)
import MicroHttp.LinkIndex (inboundOf, outboundOf)
import MicroHttp.LinkIndexStore (
    addSubtreeToIndex,
    applyChanges,
    currentIndex,
    newLinkIndexStore,
    openLinkIndex,
    relocateInIndex,
    removeSubtreeInIndex,
 )
import System.Directory (
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removeFile,
 )
import Test.Hspec

-- | A scratch document tree under build/, reset at the start of each IO test.
root :: FilePath
root = "build/link-index-store-spec"

-- | The persisted index file, kept outside the tree root so the walk never sees it.
indexPath :: FilePath
indexPath = "build/link-index-store-spec.idx"

freshTree :: IO ()
freshTree = do
    removeTree root
    createDirectoryIfMissing True root
    exists <- doesFileExist indexPath
    when exists (removeFile indexPath)

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

writeAt :: String -> String -> IO ()
writeAt rel content = do
    let full = root ++ "/" ++ rel
    createDirectoryIfMissing True (parentDir full)
    BS.writeFile full (BS.pack content)
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

removeAt :: String -> IO ()
removeAt rel = removeFile (root ++ "/" ++ rel)

spec :: Spec
spec =
    describe "MicroHttp.LinkIndexStore" $ do
        it "builds the index from the tree and answers referrer queries with no walk" $ do
            freshTree
            writeAt "a.md" "[B](./b.md) [C](./c.md)\n"
            writeAt "b.md" "leaf b\n"
            writeAt "c.md" "leaf c\n"
            store <- newLinkIndexStore
            openLinkIndex root indexPath store
            ix <- currentIndex store
            sort (inboundOf "b.md" ix) `shouldBe` ["a.md"]
            sort (inboundOf "c.md" ix) `shouldBe` ["a.md"]

        it "persists and reloads, and rebuilds when the persisted file is stale" $ do
            freshTree
            writeAt "a.md" "[B](./b.md)\n"
            writeAt "b.md" "leaf b\n"
            store1 <- newLinkIndexStore
            openLinkIndex root indexPath store1 -- builds and persists
            doesFileExist indexPath `shouldReturn` True
            -- a fresh store loads the persisted index (tree unchanged -> fingerprint matches)
            store2 <- newLinkIndexStore
            openLinkIndex root indexPath store2
            ix2 <- currentIndex store2
            sort (inboundOf "b.md" ix2) `shouldBe` ["a.md"]
            -- change the tree out-of-band, then a fresh open detects the stale fingerprint and rebuilds
            writeAt "a.md" "[C](./c.md)\n"
            writeAt "c.md" "leaf c\n"
            store3 <- newLinkIndexStore
            openLinkIndex root indexPath store3
            ix3 <- currentIndex store3
            inboundOf "b.md" ix3 `shouldBe` []
            sort (inboundOf "c.md" ix3) `shouldBe` ["a.md"]

        it "applyChanges patches a modified, added, or removed page (no walk)" $ do
            freshTree
            writeAt "a.md" "[B](./b.md)\n"
            writeAt "b.md" "leaf b\n"
            writeAt "c.md" "leaf c\n"
            store <- newLinkIndexStore
            openLinkIndex root indexPath store
            -- modify a (now links c), add d (links b), remove c
            writeAt "a.md" "[C](./c.md)\n"
            writeAt "d.md" "[B](./b.md)\n"
            removeAt "c.md"
            applyChanges root ["a.md", "d.md", "c.md"] store
            ix <- currentIndex store
            sort (inboundOf "b.md" ix) `shouldBe` ["d.md"]
            sort (inboundOf "c.md" ix) `shouldBe` ["a.md"]
            outboundOf "c.md" ix `shouldBe` []

        it "relocateInIndex relocates a moved subtree's keys and targets" $ do
            freshTree
            writeAt "index.md" "[Guide](./guide/index.md)\n"
            writeAt "guide/index.md" "# Guide\n"
            writeAt "guide/page.md" "up [Home](../index.md)\n"
            store <- newLinkIndexStore
            openLinkIndex root indexPath store
            relocateInIndex "guide" "manual" store
            ix <- currentIndex store
            -- the subtree pages are re-keyed
            outboundOf "guide/page.md" ix `shouldBe` []
            sort (outboundOf "manual/page.md" ix) `shouldBe` ["index.md"]
            -- the inbound to index.md now comes from the relocated page
            sort (inboundOf "index.md" ix) `shouldBe` ["manual/page.md"]

        it "removeSubtreeInIndex drops every page under a deleted section" $ do
            freshTree
            writeAt "index.md" "root\n"
            writeAt "sec/index.md" "# Sec\n"
            writeAt "sec/a.md" "[Home](../index.md)\n"
            store <- newLinkIndexStore
            openLinkIndex root indexPath store
            removeSubtreeInIndex "sec" store
            ix <- currentIndex store
            outboundOf "sec/a.md" ix `shouldBe` []
            inboundOf "index.md" ix `shouldBe` []

        it "addSubtreeToIndex re-reads a restored subtree's pages" $ do
            freshTree
            writeAt "index.md" "root\n"
            store <- newLinkIndexStore
            openLinkIndex root indexPath store
            -- restore a section out-of-band, then add it to the index
            writeAt "sec/index.md" "# Sec\n"
            writeAt "sec/a.md" "[Home](../index.md)\n"
            addSubtreeToIndex root "sec" store
            ix <- currentIndex store
            sort (outboundOf "sec/a.md" ix) `shouldBe` ["index.md"]
            sort (inboundOf "index.md" ix) `shouldBe` ["sec/a.md"]
