module MicroHttp.TreeMoveSpec (spec) where

import Control.Monad (forM_, void, when)
import qualified Data.ByteString.Char8 as BS
import MicroHttp.FileSystem (removeEmptyDir, removeFilePath)
import MicroHttp.LinkIndexStore (newLinkIndexStore, openLinkIndex)
import MicroHttp.OperationLog (OpType (..), Operation (..))
import MicroHttp.TreeMove (DeleteOutcome (..), MovePlan (..), ReplayEntry (..), deleteTarget, indexRelevant, movePage, moveSection, replayLog, restoreFromTrash, scanRelevant)
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

{- | A delete fixture at the root: @lonely.md@ (no inbound links but the index;
references an exclusive asset and a shared one, with a sidecar) and @other.md@ which
links to @refed.md@. The root index.md lists @lonely@ and @other@ as bullets.
-}
seedDeleteFixture :: IO ()
seedDeleteFixture = do
    removeTree root
    createDirectoryIfMissing True root
    writeAt "index.md" "# Root\n\n- [Lonely](./lonely.md)\n- [Other](./other.md)\n"
    writeAt "lonely.md" "# Lonely\n\n![o](assets/only.png) and ![s](assets/shared.png)\n"
    writeAt "other.md" "# Other\n\n![s](assets/shared.png) and [Refed](./refed.md)\n"
    writeAt "refed.md" "# Refed\n"
    writeAt "assets/only.png" "ONLY"
    writeAt "assets/shared.png" "SHARED"
    writeAt "meta/lonely.meta/images.yaml" "- local_path: assets/only.png\n  short_title: 'O'\n  description: ''\n"

trashRoot :: FilePath
trashRoot = "build/tree-delete-trash"

-- | The plan from a successful result, or a sentinel (so a wrong 'Left' fails an assertion below).
planOr :: Either String MovePlan -> MovePlan
planOr (Right plan) = plan
planOr (Left _) = MovePlan "" "" [] False

spec :: Spec
spec = do
    describe "MicroHttp.TreeMove.moveSection" $ do
        it "moves a section folder, rewrites inbound links, and relocates the listing card" $ do
            seedFixture
            result <- moveSection scanRelevant root "sub" "dest" "sub" True
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
            result <- moveSection scanRelevant root "sub" "dest" "sub" False
            isLeft result `shouldBe` False
            planApplied (planOr result) `shouldBe` False
            ("other.md" `elem` planChanged (planOr result)) `shouldBe` True
            doesDirectoryExist (root ++ "/sub") `shouldReturn` True

        it "refuses to move the root" $ do
            seedFixture
            result <- moveSection scanRelevant root "" "dest" "x" True
            isLeft result `shouldBe` True

        it "refuses to move a section into itself or a descendant" $ do
            seedFixture
            result <- moveSection scanRelevant root "sub" "sub" "inner" True
            isLeft result `shouldBe` True

        it "refuses when the destination already exists" $ do
            seedFixture
            createDirectoryIfMissing True (root ++ "/dest/sub")
            result <- moveSection scanRelevant root "sub" "dest" "sub" True
            isLeft result `shouldBe` True

    describe "MicroHttp.TreeMove.movePage" $ do
        it "moves a page cross-folder: relocates exclusive, copies shared, co-moves meta, rewrites links" $ do
            seedPageFixture
            result <- movePage scanRelevant root "a/mover.md" "b" "mover" True
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
            result <- movePage scanRelevant root "a/mover.md" "a" "renamed" True
            isLeft result `shouldBe` False
            doesFileExist (root ++ "/a/mover.md") `shouldReturn` False
            doesFileExist (root ++ "/a/renamed.md") `shouldReturn` True
            doesFileExist (root ++ "/a/meta/renamed.meta/images.yaml") `shouldReturn` True
            sib <- readAt "a/sib.md"
            sib `shouldBe` "# Sib\n\n![s](assets/shared.png) and [Mover](./renamed.md)\n"

        it "refuses when the destination page already exists" $ do
            seedPageFixture
            writeAt "b/mover.md" "# Existing\n"
            result <- movePage scanRelevant root "a/mover.md" "b" "mover" True
            isLeft result `shouldBe` True

    describe "MicroHttp.TreeMove.deleteTarget" $ do
        it "refuses a delete while another page links to the target, listing the referrer" $ do
            seedDeleteFixture
            removeTree trashRoot
            result <- deleteTarget scanRelevant root trashRoot "refed.md" "0" 0
            case result of
                Right (Refused referrers) -> map fst referrers `shouldBe` ["other.md"]
                other -> show other `shouldBe` "Right (Refused [...])"
            doesFileExist (root ++ "/refed.md") `shouldReturn` True

        it "moves an unreferenced page (md, meta, exclusive assets) to trash and removes its listing" $ do
            seedDeleteFixture
            removeTree trashRoot
            result <- deleteTarget scanRelevant root trashRoot "lonely.md" "7" 0
            case result of
                Right (Deleted tid p k) -> (tid, p, k) `shouldBe` ("7", "lonely.md", "page")
                other -> show other `shouldBe` "Right (Deleted ...)"
            doesFileExist (root ++ "/lonely.md") `shouldReturn` False
            -- Exclusive asset moved, shared asset kept.
            doesFileExist (root ++ "/assets/only.png") `shouldReturn` False
            doesFileExist (root ++ "/assets/shared.png") `shouldReturn` True
            -- Sidecar meta moved out.
            doesFileExist (root ++ "/meta/lonely.meta/images.yaml") `shouldReturn` False
            -- Trash entry written with manifest and payload.
            doesFileExist (trashRoot ++ "/7/manifest") `shouldReturn` True
            doesFileExist (trashRoot ++ "/7/page.md") `shouldReturn` True
            -- Listing bullet removed.
            idx <- readAt "index.md"
            ("Lonely" `notInfix` idx) `shouldBe` True

    describe "MicroHttp.TreeMove.restoreFromTrash" $ do
        it "restores a trashed page to its origin, re-adding the listing entry" $ do
            seedDeleteFixture
            removeTree trashRoot
            _ <- deleteTarget scanRelevant root trashRoot "lonely.md" "7" 0
            result <- restoreFromTrash root trashRoot "7"
            result `shouldBe` Right ("lonely.md", "page")
            doesFileExist (root ++ "/lonely.md") `shouldReturn` True
            doesFileExist (root ++ "/assets/only.png") `shouldReturn` True
            doesFileExist (root ++ "/meta/lonely.meta/images.yaml") `shouldReturn` True
            idx <- readAt "index.md"
            ("[Lonely](./lonely.md)" `infixOf` idx) `shouldBe` True

        it "refuses to restore when the original location is occupied" $ do
            seedDeleteFixture
            removeTree trashRoot
            _ <- deleteTarget scanRelevant root trashRoot "lonely.md" "7" 0
            writeAt "lonely.md" "# Recreated\n"
            result <- restoreFromTrash root trashRoot "7"
            isLeft result `shouldBe` True

    describe "MicroHttp.TreeMove.replayLog" $ do
        it "applies in-order ops onto a fresh corpus and skips ones whose precondition fails" $ do
            removeTree root
            removeTree trashRoot
            createDirectoryIfMissing True (root ++ "/x")
            createDirectoryIfMissing True (root ++ "/y")
            writeAt "index.md" "# Root\n"
            writeAt "x/index.md" "# X\n"
            writeAt "y/index.md" "# Y\n"
            let op t f to s =
                    Operation{opType = t, opKind = "section", opFrom = Just f, opTo = Just to, opSeq = s, opTs = "t", opTrash = Nothing}
            report <- replayLog root trashRoot [op OpMove "x" "y/x" 0, op OpMove "ghost" "y/ghost" 1]
            map (\e -> (reSeq e, isApplied (reStatus e))) report `shouldBe` [(0, True), (1, False)]
            doesDirectoryExist (root ++ "/y/x") `shouldReturn` True
            doesDirectoryExist (root ++ "/x") `shouldReturn` False

    -- The index backend (RFC-0029) must produce identical observable outcomes to the
    -- scan: it only changes which pages are read, not what the planners compute.
    describe "index-backed move/delete (RFC-0029, indexRelevant)" $ do
        it "moves a section via the index, rewriting inbound links and the listing as the scan does" $ do
            seedFixture
            store <- newLinkIndexStore
            openLinkIndex root "build/tree-move-spec.idx" store
            result <- moveSection (indexRelevant store) root "sub" "dest" "sub" True
            isLeft result `shouldBe` False
            doesFileExist (root ++ "/dest/sub/index.md") `shouldReturn` True
            other <- readAt "other.md"
            other `shouldBe` "See [Sub](./dest/sub/index.md).\n"
            destIndex <- readAt "dest/index.md"
            ("[**Sub**](./sub/index.md)" `infixOf` destIndex) `shouldBe` True

        it "refuses a referenced delete via the index, listing the same referrer" $ do
            seedDeleteFixture
            removeTree trashRoot
            store <- newLinkIndexStore
            openLinkIndex root "build/tree-move-spec.idx" store
            result <- deleteTarget (indexRelevant store) root trashRoot "refed.md" "0" 0
            case result of
                Right (Refused referrers) -> map fst referrers `shouldBe` ["other.md"]
                other -> show other `shouldBe` "Right (Refused [...])"
            doesFileExist (root ++ "/refed.md") `shouldReturn` True

        it "trashes an unreferenced page via the index, as the scan does" $ do
            seedDeleteFixture
            removeTree trashRoot
            store <- newLinkIndexStore
            openLinkIndex root "build/tree-move-spec.idx" store
            result <- deleteTarget (indexRelevant store) root trashRoot "lonely.md" "7" 0
            case result of
                Right (Deleted tid p k) -> (tid, p, k) `shouldBe` ("7", "lonely.md", "page")
                other -> show other `shouldBe` "Right (Deleted ...)"
            doesFileExist (root ++ "/lonely.md") `shouldReturn` False
            doesFileExist (trashRoot ++ "/7/manifest") `shouldReturn` True

isApplied :: String -> Bool
isApplied = (== "applied")

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
