module MicroHttp.LinkIndexStoreSpec (spec) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BS
import Data.List (sort)
import MicroHttp.FileOps (removeEmptyDir)
import MicroHttp.LinkIndex (inboundOf)
import MicroHttp.LinkIndexStore (freshIndex, newLinkIndexStore, resync)
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

freshTree :: IO ()
freshTree = removeTree root >> createDirectoryIfMissing True root

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

spec :: Spec
spec =
    describe "MicroHttp.LinkIndexStore" $ do
        it "builds lazily on first access and answers referrer queries" $ do
            freshTree
            writeAt "a.md" "[B](./b.md) [C](./c.md)\n"
            writeAt "b.md" "leaf b\n"
            writeAt "c.md" "leaf c\n"
            store <- newLinkIndexStore
            (built, ix) <- freshIndex root store
            built `shouldBe` True
            sort (inboundOf "b.md" ix) `shouldBe` ["a.md"]
            sort (inboundOf "c.md" ix) `shouldBe` ["a.md"]

        it "trusts the cached index without rebuilding when the tree is unchanged" $ do
            freshTree
            writeAt "a.md" "[B](./b.md)\n"
            writeAt "b.md" "leaf b\n"
            store <- newLinkIndexStore
            (first, _) <- freshIndex root store
            (second, _) <- freshIndex root store
            first `shouldBe` True
            second `shouldBe` False

        it "rebuilds after an out-of-band equal-length edit" $ do
            freshTree
            writeAt "a.md" "[X](./b.md)\n"
            writeAt "b.md" "leaf b\n"
            writeAt "c.md" "leaf c\n"
            store <- newLinkIndexStore
            (_, ix1) <- freshIndex root store
            sort (inboundOf "b.md" ix1) `shouldBe` ["a.md"]
            inboundOf "c.md" ix1 `shouldBe` []
            -- repoint a's only link, same byte length: only the sub-second mtime moves
            writeAt "a.md" "[X](./c.md)\n"
            (built, ix2) <- freshIndex root store
            built `shouldBe` True
            inboundOf "b.md" ix2 `shouldBe` []
            sort (inboundOf "c.md" ix2) `shouldBe` ["a.md"]

        it "re-syncs incrementally: no drift on the next check and the index equals a rebuild" $ do
            freshTree
            writeAt "a.md" "[B](./b.md)\n"
            writeAt "b.md" "leaf b\n"
            writeAt "c.md" "[B](./b.md)\n"
            store <- newLinkIndexStore
            (built, _) <- freshIndex root store
            built `shouldBe` True
            -- simulate an in-server mutation's write-set: modify, add, and remove pages
            writeAt "a.md" "[C](./c.md)\n" -- modify (equal length)
            writeAt "e.md" "[B](./b.md)\n" -- add
            removeFile (root ++ "/c.md") -- remove
            resync root store
            (drifted, maintained) <- freshIndex root store
            -- the lockstep fingerprint update means the server's own writes are not seen as drift
            drifted `shouldBe` False
            -- the incrementally maintained graph reflects the changes
            sort (inboundOf "b.md" maintained) `shouldBe` ["e.md"]
            sort (inboundOf "c.md" maintained) `shouldBe` ["a.md"]
            -- and equals a full rebuild from the current tree (the anti-drift invariant)
            store2 <- newLinkIndexStore
            (_, rebuilt) <- freshIndex root store2
            maintained `shouldBe` rebuilt
