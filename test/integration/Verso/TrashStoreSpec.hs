module Verso.TrashStoreSpec (spec) where

import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.OperationLog as OperationLog
import qualified Verso.OperationStore as OperationStore
import qualified Verso.Trash as Trash
import qualified Verso.TrashStore as TrashStore

spec :: Spec
spec =
    describe "Verso.TrashStore startup catalogue" $
        it "given trash manifests and delete records, when opened, then entries are newest-first and later reads use memory" $ do
            let root = "build/trash-store-spec"
                trashRoot = root ++ "/trash"
                logPath = root ++ "/operation-log"
            _ <- Process.runProcess "rm" ["-rf", root] Nothing Nothing
            Directory.createDirectoryIfMissing True (trashRoot ++ "/2")
            Directory.createDirectoryIfMissing True (trashRoot ++ "/10")
            writeFile (trashRoot ++ "/2/manifest") (Trash.renderManifest (manifest "older.md" 2))
            writeFile (trashRoot ++ "/10/manifest") (Trash.renderManifest (manifest "newer.md" 10))
            mapM_ (OperationLog.appendOperation logPath) [deleteOp "older.md" 2 "2026-08-05T10:00:00.000+1200", deleteOp "newer.md" 10 "2026-08-06T10:00:00.000+1200"]

            operationStore <- OperationStore.openOperationStore logPath
            store <- TrashStore.openTrashStore trashRoot operationStore
            Directory.removeFile (trashRoot ++ "/10/manifest")
            entries <- TrashStore.trashEntries store

            entries
                `shouldBe` [ TrashStore.TrashEntry "10" "newer.md" "page" "2026-08-06T10:00:00.000+1200"
                           , TrashStore.TrashEntry "2" "older.md" "page" "2026-08-05T10:00:00.000+1200"
                           ]

manifest :: String -> Int -> Trash.Manifest
manifest path seqNo = Trash.Manifest path "page" seqNo Nothing []

deleteOp :: String -> Int -> String -> OperationLog.Operation
deleteOp path seqNo timestamp =
    OperationLog.Operation OperationLog.OpDelete "page" (Just path) Nothing seqNo timestamp (Just (show seqNo))
