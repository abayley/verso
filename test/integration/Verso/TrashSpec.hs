module Verso.TrashSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.Trash as Trash
import qualified Verso.TreePath as TreePath

base :: FilePath
base = "build/trash-mechanics-spec"

root :: FilePath
root = base ++ "/tree"

trashRoot :: FilePath
trashRoot = base ++ "/trash"

-- | Parses a tree path the spec knows to be valid.
tp :: String -> TreePath.TreePath
tp raw = case TreePath.parse raw of
    Just p -> p
    Nothing -> error ("TrashSpec: fixture path does not parse: " ++ raw)

-- | Parses a trash id the spec knows to be valid.
tid :: String -> TreePath.TrashId
tid raw = case TreePath.parseTrashId raw of
    Just t -> t
    Nothing -> error ("TrashSpec: fixture trash id does not parse: " ++ raw)

writeAt :: String -> String -> IO ()
writeAt rel content = do
    let page = tp rel
    Directory.createDirectoryIfMissing True (TreePath.resolve root (TreePath.parent page))
    BS.writeFile (TreePath.resolve root page) (BS.pack content)

-- | A fresh, empty tree and trash root.
fresh :: IO ()
fresh = do
    _ <- Process.runProcess "rm" ["-rf", base] Nothing Nothing
    Directory.createDirectoryIfMissing True root

-- | An entry directory created empty under the trash root.
entryDirFor :: String -> IO FilePath
entryDirFor rawId = do
    let dir = TreePath.trashEntryDir trashRoot (tid rawId)
    Directory.createDirectoryIfMissing True dir
    pure dir

spec :: Spec
spec =
    describe "Verso.Trash entry mechanics" $ do
        it "given a page moved into an entry, when the entry is listed, then it reports the entry's origin and kind" $ do
            fresh
            writeAt "lonely.md" "# Lonely\n"
            entryDir <- entryDirFor "7"
            item <- Trash.moveIntoTrash root entryDir "page.md" (tp "lonely.md") False
            Trash.writeManifest entryDir (Trash.Manifest "lonely.md" "page" 7 Nothing (maybe [] pure item))
            Directory.doesFileExist (root ++ "/lonely.md") `shouldReturn` False
            Directory.doesFileExist (entryDir ++ "/page.md") `shouldReturn` True
            Trash.listTrash trashRoot `shouldReturn` [("7", "lonely.md", "page")]

        it "given a stored item, when it is restored, then it returns to its origin tree path" $ do
            fresh
            writeAt "lonely.md" "# Lonely\n"
            entryDir <- entryDirFor "7"
            item <- Trash.moveIntoTrash root entryDir "page.md" (tp "lonely.md") False
            case item of
                Nothing -> fail "the page was not moved into the entry"
                Just stored -> do
                    Trash.restoreItem root entryDir stored
                    Directory.doesFileExist (root ++ "/lonely.md") `shouldReturn` True

        it "given an occupied origin, when occupancy is checked, then it reports occupied" $ do
            fresh
            writeAt "here.md" "# Here\n"
            Trash.targetOccupied root (tp "here.md") "page" `shouldReturn` True

        it "given a free origin, when occupancy is checked, then it reports free" $ do
            fresh
            Trash.targetOccupied root (tp "gone.md") "page" `shouldReturn` False

        it "given an entry, when it is purged, then it is gone and a second purge reports nothing removed" $ do
            fresh
            writeAt "lonely.md" "# Lonely\n"
            entryDir <- entryDirFor "7"
            _ <- Trash.moveIntoTrash root entryDir "page.md" (tp "lonely.md") False
            Trash.writeManifest entryDir (Trash.Manifest "lonely.md" "page" 7 Nothing [])
            Trash.deleteTrashEntry trashRoot (tid "7") `shouldReturn` True
            Directory.doesDirectoryExist entryDir `shouldReturn` False
            Trash.deleteTrashEntry trashRoot (tid "7") `shouldReturn` False

        it "given a directory that is absent, when it is moved into an entry, then no item is produced" $ do
            fresh
            entryDir <- entryDirFor "7"
            item <- Trash.moveDirIntoTrash root entryDir "meta" (tp "absent/meta/x.meta")
            item `shouldBe` Nothing
            Monad.void (pure ())
