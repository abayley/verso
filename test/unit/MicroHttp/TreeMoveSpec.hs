module MicroHttp.TreeMoveSpec (spec) where

import Control.Monad (forM_, void, when)
import qualified Data.ByteString.Char8 as BS
import MicroHttp.FileOps (removeEmptyDir, removeFilePath)
import MicroHttp.TreeMove (MovePlan (..), moveSection)
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

-- | The plan from a successful result, or a sentinel (so a wrong 'Left' fails an assertion below).
planOr :: Either String MovePlan -> MovePlan
planOr (Right plan) = plan
planOr (Left _) = MovePlan "" "" [] False

spec :: Spec
spec =
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
