module Verso.StructureSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.Draft as Draft
import qualified Verso.Git as Git
import qualified Verso.Maintenance as Maintenance
import qualified Verso.OperationLog as OperationLog
import qualified Verso.OperationStore as OperationStore
import qualified Verso.Structure as Structure
import qualified Verso.TrashStore as TrashStore
import qualified Verso.TreeMove as TreeMove
import qualified Verso.TreePath as TreePath

base :: FilePath
base = "build/structure-spec"

root :: FilePath
root = base ++ "/tree"

trashRoot :: FilePath
trashRoot = base ++ "/trash"

logPath :: FilePath
logPath = base ++ "/operation-log"

draftRoot :: FilePath
draftRoot = base ++ "/drafts"

author :: Git.Identity
author = Git.Identity "Spec" "spec@verso.local"

-- | Parses a tree path the spec knows to be valid.
tp :: String -> TreePath.TreePath
tp raw = case TreePath.parse raw of
    Just p -> p
    Nothing -> error ("StructureSpec: fixture path does not parse: " ++ raw)

writeAt :: String -> String -> IO ()
writeAt rel content = do
    let page = tp rel
    Directory.createDirectoryIfMissing True (TreePath.resolve root (TreePath.parent page))
    BS.writeFile (TreePath.resolve root page) (BS.pack content)

{- | A fresh tree -- a section @sub@ with a page, a destination section @dest@, an
unreferenced page @lonely.md@, and @other.md@ linking @refed.md@ -- with an empty
operation log and trash, and a 'Structure.Structure' over them whose maintenance
hooks and revision commit record what they were told, in order.
-}
fixture :: Structure.Versioning -> IO (Structure.Structure, IO [String])
fixture versioning = do
    _ <- Process.runProcess "rm" ["-rf", base] Nothing Nothing
    Directory.createDirectoryIfMissing True root
    writeAt "index.md" "# Root\n\n- [Lonely](./lonely.md)\n- [Other](./other.md)\n\n<div class=\"grid cards\" markdown>\n\n- :material-x: [**Sub**](./sub/index.md) <span class=\"oracle-card-description\">d</span>\n\n</div>\n"
    writeAt "dest/index.md" "# Dest\n\n<div class=\"grid cards\" markdown>\n\n</div>\n"
    writeAt "sub/index.md" "# Sub\n"
    writeAt "sub/page.md" "# Page\n"
    writeAt "lonely.md" "# Lonely\n"
    writeAt "other.md" "See [Refed](./refed.md).\n"
    writeAt "refed.md" "# Refed\n"
    events <- IORef.newIORef []
    let record event = IORef.modifyIORef events (++ [event])
        maintenance event = case event of
            Maintenance.Moved from to -> record ("index move " ++ from ++ " -> " ++ to)
            Maintenance.Deleted path -> record ("index delete " ++ path)
            Maintenance.Created path -> record ("index create " ++ path)
            Maintenance.Restored path -> record ("index restore " ++ path)
            Maintenance.Saved path -> record ("index save " ++ path)
        structure =
            Structure.Structure
                { Structure.structureRoot = root
                , Structure.structureTrashRoot = trashRoot
                , Structure.structureLock = Nothing
                , Structure.structurePages = TreeMove.scanRelevant
                , Structure.structureMaintenance = maintenance
                , Structure.structureOperations = OperationStore.uncachedOperationStore logPath
                , Structure.structureTrash = TrashStore.uncachedTrashStore trashRoot logPath
                , Structure.structureVersioning = versioning
                , Structure.structureCommit = \_ message -> record ("commit " ++ message)
                }
    pure (structure, IORef.readIORef events)

-- | The logged operations as @(type, kind, from, to, trash)@ tuples.
loggedOperations :: IO [(OperationLog.OpType, String, Maybe String, Maybe String, Maybe String)]
loggedOperations = do
    ops <- OperationLog.readOperations logPath
    pure [(OperationLog.opType op, OperationLog.opKind op, OperationLog.opFrom op, OperationLog.opTo op, OperationLog.opTrash op) | op <- ops]

isRefused :: Either Structure.Refusal a -> Bool
isRefused (Left (Structure.Refused _)) = True
isRefused _ = False

spec :: Spec
spec =
    describe "Verso.Structure" $ do
        describe "move" $ do
            it "given a section, when it is moved and confirmed, then the move is logged, the index and the revision are told, in that order" $ do
                (structure, recorded) <- fixture Structure.noVersioning
                result <- Structure.move structure author (tp "sub") (tp "dest") "" True
                fmap TreeMove.planApplied result `shouldBe` Right True
                Directory.doesDirectoryExist (root ++ "/dest/sub") `shouldReturn` True
                loggedOperations `shouldReturn` [(OperationLog.OpMove, "section", Just "sub", Just "dest/sub", Nothing)]
                recorded `shouldReturn` ["index move sub -> dest/sub", "commit Move sub to dest/sub"]

            it "given a move preview, when it is requested, then nothing is logged and nobody is told" $ do
                (structure, recorded) <- fixture Structure.noVersioning
                result <- Structure.move structure author (tp "sub") (tp "dest") "" False
                fmap TreeMove.planApplied result `shouldBe` Right False
                loggedOperations `shouldReturn` []
                recorded `shouldReturn` []

            it "given an occupied destination, when a move is requested, then it is refused and nothing is logged" $ do
                (structure, recorded) <- fixture Structure.noVersioning
                Directory.createDirectoryIfMissing True (root ++ "/dest/sub")
                result <- Structure.move structure author (tp "sub") (tp "dest") "" True
                isRefused result `shouldBe` True
                loggedOperations `shouldReturn` []
                recorded `shouldReturn` []

            it "given versioning on and a staged draft, when the section is moved, then the draft travels with it" $ do
                let versioning = Structure.noVersioning{Structure.versioningOn = True, Structure.draftStagingRoot = draftRoot}
                (structure, _) <- fixture versioning
                Draft.writeDraft draftRoot (tp "sub/page.md") (BS.pack "draft body")
                _ <- Structure.move structure author (tp "sub") (tp "dest") "" True
                Draft.hasDraft draftRoot (tp "dest/sub/page.md") `shouldReturn` True
                Draft.hasDraft draftRoot (tp "sub/page.md") `shouldReturn` False

        describe "delete" $ do
            it "given an unreferenced page, when it is deleted, then it is trashed under the log seq, logged, catalogued and the index and revision are told" $ do
                (structure, recorded) <- fixture Structure.noVersioning
                result <- Structure.delete structure author (tp "lonely.md")
                fmap (\d -> (TreePath.render (Structure.deletedPath d), Structure.deletedKind d, TreePath.renderTrashId (Structure.deletedTrashId d))) result
                    `shouldBe` Right ("lonely.md", "page", "0")
                Directory.doesFileExist (root ++ "/lonely.md") `shouldReturn` False
                loggedOperations `shouldReturn` [(OperationLog.OpDelete, "page", Just "lonely.md", Nothing, Just "0")]
                entries <- TrashStore.trashEntries (Structure.structureTrash structure)
                map (\e -> (TrashStore.entryId e, TrashStore.entryPath e)) entries `shouldBe` [("0", "lonely.md")]
                recorded `shouldReturn` ["index delete lonely.md", "commit Delete lonely.md"]

            it "given a page another page links to, when it is deleted, then the referrers are reported and nothing is logged" $ do
                (structure, recorded) <- fixture Structure.noVersioning
                result <- Structure.delete structure author (tp "refed.md")
                case result of
                    Left (Structure.StillReferenced referrers) -> map fst referrers `shouldBe` ["other.md"]
                    other -> show (fmap Structure.deletedKind other) `shouldBe` "Left (StillReferenced [...])"
                loggedOperations `shouldReturn` []
                recorded `shouldReturn` []

        describe "restore" $ do
            it "given a trashed page, when it is restored, then it is back, logged, forgotten by the catalogue and the index and revision are told" $ do
                (structure, recorded) <- fixture Structure.noVersioning
                Right deleted <- Structure.delete structure author (tp "lonely.md")
                result <- Structure.restore structure author (Structure.deletedTrashId deleted)
                fmap (\r -> (TreePath.render (Structure.restoredPath r), Structure.restoredKind r)) result `shouldBe` Right ("lonely.md", "page")
                Directory.doesFileExist (root ++ "/lonely.md") `shouldReturn` True
                ops <- loggedOperations
                last ops `shouldBe` (OperationLog.OpRestore, "page", Nothing, Just "lonely.md", Just "0")
                TrashStore.trashEntries (Structure.structureTrash structure) `shouldReturn` []
                events <- recorded
                drop 2 events `shouldBe` ["index restore lonely.md", "commit Restore lonely.md"]

            it "given an unknown trash id, when a restore is requested, then it is refused" $ do
                (structure, _) <- fixture Structure.noVersioning
                let Just missing = TreePath.parseTrashId "99"
                result <- Structure.restore structure author missing
                isRefused result `shouldBe` True

        describe "undo" $ do
            it "given an empty log, when an undo is requested, then it is refused" $ do
                (structure, _) <- fixture Structure.noVersioning
                result <- Structure.undo structure author Nothing
                isRefused result `shouldBe` True

            it "given a logged move, when the latest operation is undone, then the section is back and the inverse move is logged" $ do
                (structure, _) <- fixture Structure.noVersioning
                _ <- Structure.move structure author (tp "sub") (tp "dest") "" True
                result <- Structure.undo structure author Nothing
                case result of
                    Right (Structure.UndoneMove from to) -> (TreePath.render from, TreePath.render to) `shouldBe` ("dest/sub", "sub")
                    other -> show (Monad.void other) `shouldBe` "Right (UndoneMove ...)"
                Directory.doesDirectoryExist (root ++ "/sub") `shouldReturn` True
                ops <- loggedOperations
                last ops `shouldBe` (OperationLog.OpMove, "section", Just "dest/sub", Just "sub", Nothing)

            it "given a section moved to a slug ending in .md, when its undo is undone, then it returns to the recorded path" $ do
                (structure, _) <- fixture Structure.noVersioning
                _ <- Structure.move structure author (tp "sub") (tp "dest") "notes.md" True
                _ <- Structure.undo structure author Nothing
                result <- Structure.undo structure author Nothing
                case result of
                    Right (Structure.UndoneMove from to) -> (TreePath.render from, TreePath.render to) `shouldBe` ("sub", "dest/notes.md")
                    other -> show (Monad.void other) `shouldBe` "Right (UndoneMove ...)"
                Directory.doesDirectoryExist (root ++ "/dest/notes.md") `shouldReturn` True
                Directory.doesDirectoryExist (root ++ "/dest/notes") `shouldReturn` False

            it "given a logged delete, when it is undone, then the page is restored and the restore is logged" $ do
                (structure, _) <- fixture Structure.noVersioning
                _ <- Structure.delete structure author (tp "lonely.md")
                result <- Structure.undo structure author Nothing
                case result of
                    Right (Structure.UndoneDelete restored) -> TreePath.render (Structure.restoredPath restored) `shouldBe` "lonely.md"
                    other -> show (Monad.void other) `shouldBe` "Right (UndoneDelete ...)"
                Directory.doesFileExist (root ++ "/lonely.md") `shouldReturn` True

        describe "create" $ do
            it "given a parent section and a title, when a page is created, then the seeded page exists and the index is told" $ do
                (structure, recorded) <- fixture Structure.noVersioning
                result <- Structure.create structure (tp "dest") TreePath.Page "New Page"
                fmap (\c -> (TreePath.render (Structure.createdPath c), TreePath.render (Structure.createdEditPath c))) result
                    `shouldBe` Right ("dest/new-page.md", "dest/new-page.md")
                content <- BS.readFile (root ++ "/dest/new-page.md")
                BS.unpack content `shouldBe` "---\nname: New Page\n---\n\n# New Page\n"
                recorded `shouldReturn` ["index create dest/new-page.md"]

            it "given a section title, when a section is created, then its index page is the page to edit" $ do
                (structure, _) <- fixture Structure.noVersioning
                result <- Structure.create structure TreePath.root TreePath.Section "Guides"
                fmap (\c -> (TreePath.render (Structure.createdPath c), TreePath.render (Structure.createdEditPath c))) result
                    `shouldBe` Right ("guides", "guides/index.md")

            it "given a blank title, when a create is requested, then it is refused" $ do
                (structure, _) <- fixture Structure.noVersioning
                result <- Structure.create structure TreePath.root TreePath.Page "   "
                isRefused result `shouldBe` True

        describe "purge" $ do
            it "given a trashed page, when its entry is purged, then it is gone from the trash and the catalogue" $ do
                (structure, _) <- fixture Structure.noVersioning
                _ <- Structure.delete structure author (tp "lonely.md")
                Structure.purge structure "0" `shouldReturn` True
                Directory.doesDirectoryExist (trashRoot ++ "/0") `shouldReturn` False
                TrashStore.trashEntries (Structure.structureTrash structure) `shouldReturn` []

            it "given two trashed pages, when the entries matching a predicate are purged, then those are gone and the rest are kept" $ do
                (structure, _) <- fixture Structure.noVersioning
                _ <- Structure.delete structure author (tp "lonely.md")
                _ <- Structure.delete structure author (tp "sub/page.md")
                (purged, kept) <- Structure.purgeMatching structure ((== "0") . TrashStore.entryId)
                map TrashStore.entryId purged `shouldBe` ["0"]
                map TrashStore.entryId kept `shouldBe` ["1"]
                Directory.doesDirectoryExist (trashRoot ++ "/0") `shouldReturn` False
                Directory.doesDirectoryExist (trashRoot ++ "/1") `shouldReturn` True

            it "given an id that is not a trash id, when a purge is requested, then nothing is removed" $ do
                (structure, _) <- fixture Structure.noVersioning
                Structure.purge structure "../tree" `shouldReturn` False
