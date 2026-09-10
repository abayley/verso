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
            it "given a move operation, when it is rendered and parsed back, then the original is returned" $
                OperationLog.parseOperation (OperationLog.renderOperation moveOp) `shouldBe` Just moveOp

            it "given a delete operation with a trash id and no destination, when it is rendered and parsed back, then the original is returned" $
                OperationLog.parseOperation (OperationLog.renderOperation deleteOp) `shouldBe` Just deleteOp

            it "given a malformed line, when it is parsed, then nothing is returned" $
                OperationLog.parseOperation "{not json}" `shouldBe` Nothing

        describe "append/read and nextSeq" $ do
            it "given several operations, when they are appended, then they read back in order" $ do
                createParent
                cleanLog
                OperationLog.appendOperation logPath moveOp
                OperationLog.appendOperation logPath deleteOp
                ops <- OperationLog.readOperations logPath
                ops `shouldBe` [moveOp, deleteOp]

            it "given a log read in chunks smaller than a line, when read, then the operations equal the whole read" $ do
                createParent
                cleanLog
                Monad.forM_ [0 .. 40 :: Int] $ \n -> OperationLog.appendOperation logPath moveOp{OperationLog.opSeq = n}
                whole <- OperationLog.readOperations logPath
                chunked <- OperationLog.readOperationsChunked 7 logPath
                length whole `shouldBe` 41
                chunked `shouldBe` whole

            it "given a missing log, when read, then there are no operations" $ do
                createParent
                cleanLog
                OperationLog.readOperations logPath `shouldReturn` []

            it "given an empty log and then a populated one, when the next sequence number is asked for, then it is 0 and then one past the maximum" $ do
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
