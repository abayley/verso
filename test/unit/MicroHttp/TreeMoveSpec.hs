module MicroHttp.TreeMoveSpec (spec) where

import Control.Monad (forM_, void, when)
import qualified Data.ByteString.Char8 as BS
import MicroHttp.FileOps (removeEmptyDir, removeFilePath)
import MicroHttp.TreeMove (MovePlan (..), movePage, moveSection)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import Test.Hspec

root :: FilePath
root = "build/tree-move-spec"

-- | Recursively empties and recreates the fixture tree (no runIO/beforeAll here).
removeTree :: FilePath -> IO ()
removeTree dir = do
    isDir <- doesDirectoryExist dir
    when isDir $ do
        names <- listDirectory dir
        forM_ names $ \name -> do
            let path = dir ++ "/" ++ name
            sub <- doesDirectoryExist path
            if sub then removeTree path else void (removeFilePath path)
        _ <- removeEmptyDir dir
        pure ()

writeAt :: FilePath -> String -> IO ()
writeAt rel content = do
    let path = root ++ "/" ++ rel
    createDirectoryIfMissing True (parentOf path)
    BS.writeFile path (BS.pack content)
  where
    parentOf = reverse . drop 1 . dropWhile (/= '/') . reverse

readAt :: FilePath -> IO String
readAt rel = fmap BS.unpack (BS.readFile (root ++ "/" ++ rel))

{- | A small fixture: a section @sub@ at the root, a destination folder @dest@, and
an outside page linking into @sub@. The root index.md lists @sub@ as a grid card.
-}
seedFixture :: IO ()
seedFixture = do
    removeTree root
    createDirectoryIfMissing True root
    writeAt
        "index.md"
        "# Root\n\n<div class=\"grid cards\" markdown>\n\n- :material-x: [**Sub**](./sub/index.md) <span class=\"oracle-card-description\">d</span>\n\n</div>\n"
    writeAt "dest/index.md" "# Dest\n\n<div class=\"grid cards\" markdown>\n\n</div>\n"
    writeAt "sub/index.md" "# Sub\n\nUp [Home](../index.md).\n"
    writeAt "sub/page.md" "# Page\n\nSee [Home](../index.md).\n"
    writeAt "other.md" "See [Sub](./sub/index.md).\n"

{- | A page-move fixture: folder @a@ holds @mover.md@ (referencing an exclusive and
a shared asset) and a peer @sib.md@ (referencing the shared asset and linking the
mover); @mover.md@ has a sidecar image entry. Folder @b@ is the destination.
-}
seedPageFixture :: IO ()
seedPageFixture = do
    removeTree root
    createDirectoryIfMissing True root
    writeAt "a/index.md" "# A\n\n- [Mover](./mover.md)\n- [Sibling](./sib.md)\n"
    writeAt "a/mover.md" "# Mover\n\n![e](assets/excl.png) and ![s](assets/shared.png) and [Sib](./sib.md)\n"
    writeAt "a/sib.md" "# Sib\n\n![s](assets/shared.png) and [Mover](./mover.md)\n"
    writeAt "a/assets/excl.png" "EXCL"
    writeAt "a/assets/shared.png" "SHARED"
    writeAt "a/meta/mover.meta/images.yaml" "- local_path: assets/excl.png\n  short_title: 'E'\n  description: ''\n"
    writeAt "b/index.md" "# B\n"

-- | The plan from a successful result, or a sentinel (so a wrong 'Left' fails an assertion below).
planOr :: Either String MovePlan -> MovePlan
planOr (Right plan) = plan
planOr (Left _) = MovePlan "" "" [] False

spec :: Spec
spec = do
    describe "MicroHttp.TreeMove.moveSection" $ do
        it "moves a section folder, rewrites inbound links, and relocates the listing card" $ do
            seedFixture
            result <- moveSection root "sub" "dest" "sub" True
            isLeft result `shouldBe` False
            planApplied (planOr result) `shouldBe` True
            -- The folder moved.
            doesDirectoryExist (root ++ "/sub") `shouldReturn` False
            doesFileExist (root ++ "/dest/sub/index.md") `shouldReturn` True
            -- The outside inbound link is repointed.
            other <- readAt "other.md"
            other `shouldBe` "See [Sub](./dest/sub/index.md).\n"
            -- The moved page's link to a non-moved target is repointed.
            moved <- readAt "dest/sub/page.md"
            moved `shouldBe` "# Page\n\nSee [Home](../../index.md).\n"
            -- The source listing card is removed.
            srcIndex <- readAt "index.md"
            ("Sub" `notInfix` srcIndex) `shouldBe` True
            -- The destination listing gains the card.
            destIndex <- readAt "dest/index.md"
            ("[**Sub**](./sub/index.md)" `infixOf` destIndex) `shouldBe` True

        it "previews without writing when confirm is False" $ do
            seedFixture
            result <- moveSection root "sub" "dest" "sub" False
            isLeft result `shouldBe` False
            planApplied (planOr result) `shouldBe` False
            ("other.md" `elem` planChanged (planOr result)) `shouldBe` True
            doesDirectoryExist (root ++ "/sub") `shouldReturn` True

        it "refuses to move the root" $ do
            seedFixture
            result <- moveSection root "" "dest" "x" True
            isLeft result `shouldBe` True

        it "refuses to move a section into itself or a descendant" $ do
            seedFixture
            result <- moveSection root "sub" "sub" "inner" True
            isLeft result `shouldBe` True

        it "refuses when the destination already exists" $ do
            seedFixture
            createDirectoryIfMissing True (root ++ "/dest/sub")
            result <- moveSection root "sub" "dest" "sub" True
            isLeft result `shouldBe` True

    describe "MicroHttp.TreeMove.movePage" $ do
        it "moves a page cross-folder: relocates exclusive, copies shared, co-moves meta, rewrites links" $ do
            seedPageFixture
            result <- movePage root "a/mover.md" "b" "mover" True
            isLeft result `shouldBe` False
            doesFileExist (root ++ "/a/mover.md") `shouldReturn` False
            doesFileExist (root ++ "/b/mover.md") `shouldReturn` True
            -- Exclusive asset relocated (gone from source, present at destination).
            doesFileExist (root ++ "/a/assets/excl.png") `shouldReturn` False
            doesFileExist (root ++ "/b/assets/excl.png") `shouldReturn` True
            -- Shared asset copied (stays at source, present at destination).
            doesFileExist (root ++ "/a/assets/shared.png") `shouldReturn` True
            doesFileExist (root ++ "/b/assets/shared.png") `shouldReturn` True
            -- Sidecar meta directory co-moved.
            doesFileExist (root ++ "/a/meta/mover.meta/images.yaml") `shouldReturn` False
            doesFileExist (root ++ "/b/meta/mover.meta/images.yaml") `shouldReturn` True
            -- Moved page keeps bare asset refs and repoints its outward link.
            moved <- readAt "b/mover.md"
            moved `shouldBe` "# Mover\n\n![e](assets/excl.png) and ![s](assets/shared.png) and [Sib](../a/sib.md)\n"
            -- The peer's inbound link is repointed.
            sib <- readAt "a/sib.md"
            sib `shouldBe` "# Sib\n\n![s](assets/shared.png) and [Mover](../b/mover.md)\n"
            -- Listing bullet relocated.
            aIndex <- readAt "a/index.md"
            ("Mover" `notInfix` aIndex) `shouldBe` True
            bIndex <- readAt "b/index.md"
            ("[Mover](./mover.md)" `infixOf` bIndex) `shouldBe` True

        it "renames a page in the same folder, co-moving meta and fixing inbound links" $ do
            seedPageFixture
            result <- movePage root "a/mover.md" "a" "renamed" True
            isLeft result `shouldBe` False
            doesFileExist (root ++ "/a/mover.md") `shouldReturn` False
            doesFileExist (root ++ "/a/renamed.md") `shouldReturn` True
            doesFileExist (root ++ "/a/meta/renamed.meta/images.yaml") `shouldReturn` True
            sib <- readAt "a/sib.md"
            sib `shouldBe` "# Sib\n\n![s](assets/shared.png) and [Mover](./renamed.md)\n"

        it "refuses when the destination page already exists" $ do
            seedPageFixture
            writeAt "b/mover.md" "# Existing\n"
            result <- movePage root "a/mover.md" "b" "mover" True
            isLeft result `shouldBe` True

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

infixOf :: String -> String -> Bool
infixOf needle haystack = any (prefix needle) (tails haystack)
  where
    prefix [] _ = True
    prefix _ [] = False
    prefix (x : xs) (y : ys) = x == y && prefix xs ys
    tails [] = [[]]
    tails s@(_ : rest) = s : tails rest

notInfix :: String -> String -> Bool
notInfix needle haystack = not (infixOf needle haystack)
