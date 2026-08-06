module Verso.OperationStoreSpec (spec) where

import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.OperationLog as OperationLog
import qualified Verso.OperationStore as OperationStore

spec :: Spec
spec =
    describe "Verso.OperationStore warm catalogue" $ do
        it "given a durable operation log, when the store is opened, then later reads use the startup catalogue" $ do
            let root = "build/operation-store-spec"
                logPath = root ++ "/operation-log"
                operation = moveOp 4
            _ <- Process.runProcess "rm" ["-rf", root] Nothing Nothing
            Directory.createDirectoryIfMissing True root
            OperationLog.appendOperation logPath operation

            store <- OperationStore.openOperationStore logPath
            Directory.removeFile logPath

            OperationStore.readOperations store `shouldReturn` [operation]
        it "given an open store, when an operation is appended, then memory, sequence allocation, and the durable log stay consistent" $ do
            let root = "build/operation-store-append-spec"
                logPath = root ++ "/operation-log"
                operation = moveOp 0
            _ <- Process.runProcess "rm" ["-rf", root] Nothing Nothing
            Directory.createDirectoryIfMissing True root
            store <- OperationStore.openOperationStore logPath

            OperationStore.nextSeq store `shouldReturn` 0
            OperationStore.appendOperation store operation

            OperationStore.readOperations store `shouldReturn` [operation]
            OperationStore.nextSeq store `shouldReturn` 1
            OperationLog.readOperations logPath `shouldReturn` [operation]

moveOp :: Int -> OperationLog.Operation
moveOp sequenceNumber =
    OperationLog.Operation
        OperationLog.OpMove
        "page"
        (Just "from.md")
        (Just "to.md")
        sequenceNumber
        "2026-08-06T10:00:00.000+1200"
        Nothing
