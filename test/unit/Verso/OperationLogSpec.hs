module Verso.OperationLogSpec (spec) where

import qualified Control.Monad as Monad
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.OperationLog as OperationLog

logPath :: FilePath
logPath = "build/operation-log-spec/log"

cleanLog :: IO ()
cleanLog = do
    exists <- Directory.doesFileExist logPath
    Monad.when exists (Directory.removeFile logPath)

moveOp :: OperationLog.Operation
moveOp =
    OperationLog.Operation
        { OperationLog.opType = OperationLog.OpMove
        , OperationLog.opKind = "section"
        , OperationLog.opFrom = Just "a/b"
        , OperationLog.opTo = Just "c/b"
        , OperationLog.opSeq = 0
        , OperationLog.opTs = "2026-06-24T09:00:00.000+1200"
        , OperationLog.opTrash = Nothing
        }

deleteOp :: OperationLog.Operation
deleteOp =
    OperationLog.Operation
        { OperationLog.opType = OperationLog.OpDelete
        , OperationLog.opKind = "page"
        , OperationLog.opFrom = Just "a/old.md"
        , OperationLog.opTo = Nothing
        , OperationLog.opSeq = 1
        , OperationLog.opTs = "2026-06-24T09:01:00.000+1200"
        , OperationLog.opTrash = Just "trash-7"
        }

spec :: Spec
spec =
    describe "Verso.OperationLog" $ do
        describe "render/parse round-trip" $ do
            it "round-trips a move operation" $
                OperationLog.parseOperation (OperationLog.renderOperation moveOp) `shouldBe` Just moveOp

            it "round-trips a delete operation with a trash id and no 'to'" $
                OperationLog.parseOperation (OperationLog.renderOperation deleteOp) `shouldBe` Just deleteOp

            it "is Nothing for a malformed line" $
                OperationLog.parseOperation "{not json}" `shouldBe` Nothing

        describe "append/read and nextSeq" $ do
            it "appends operations and reads them back in order" $ do
                createParent
                cleanLog
                OperationLog.appendOperation logPath moveOp
                OperationLog.appendOperation logPath deleteOp
                ops <- OperationLog.readOperations logPath
                ops `shouldBe` [moveOp, deleteOp]

            it "gives seq 0 for an empty log and one past the maximum otherwise" $ do
                createParent
                cleanLog
                empty <- OperationLog.nextSeq logPath
                empty `shouldBe` 0
                OperationLog.appendOperation logPath moveOp
                OperationLog.appendOperation logPath deleteOp
                next <- OperationLog.nextSeq logPath
                next `shouldBe` 2
  where
    createParent = Directory.createDirectoryIfMissing True "build/operation-log-spec"
