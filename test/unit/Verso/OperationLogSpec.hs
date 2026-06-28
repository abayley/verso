module Verso.OperationLogSpec (spec) where

import Control.Monad (when)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import Test.Hspec
import Verso.OperationLog (
    OpType (..),
    Operation (..),
    appendOperation,
    nextSeq,
    parseOperation,
    readOperations,
    renderOperation,
 )

logPath :: FilePath
logPath = "build/operation-log-spec/log"

cleanLog :: IO ()
cleanLog = do
    exists <- doesFileExist logPath
    when exists (removeFile logPath)

moveOp :: Operation
moveOp =
    Operation
        { opType = OpMove
        , opKind = "section"
        , opFrom = Just "a/b"
        , opTo = Just "c/b"
        , opSeq = 0
        , opTs = "2026-06-24T09:00:00.000+1200"
        , opTrash = Nothing
        }

deleteOp :: Operation
deleteOp =
    Operation
        { opType = OpDelete
        , opKind = "page"
        , opFrom = Just "a/old.md"
        , opTo = Nothing
        , opSeq = 1
        , opTs = "2026-06-24T09:01:00.000+1200"
        , opTrash = Just "trash-7"
        }

spec :: Spec
spec =
    describe "Verso.OperationLog" $ do
        describe "render/parse round-trip" $ do
            it "round-trips a move operation" $
                parseOperation (renderOperation moveOp) `shouldBe` Just moveOp

            it "round-trips a delete operation with a trash id and no 'to'" $
                parseOperation (renderOperation deleteOp) `shouldBe` Just deleteOp

            it "is Nothing for a malformed line" $
                parseOperation "{not json}" `shouldBe` Nothing

        describe "append/read and nextSeq" $ do
            it "appends operations and reads them back in order" $ do
                createParent
                cleanLog
                appendOperation logPath moveOp
                appendOperation logPath deleteOp
                ops <- readOperations logPath
                ops `shouldBe` [moveOp, deleteOp]

            it "gives seq 0 for an empty log and one past the maximum otherwise" $ do
                createParent
                cleanLog
                empty <- nextSeq logPath
                empty `shouldBe` 0
                appendOperation logPath moveOp
                appendOperation logPath deleteOp
                next <- nextSeq logPath
                next `shouldBe` 2
  where
    createParent = createDirectoryIfMissing True "build/operation-log-spec"
