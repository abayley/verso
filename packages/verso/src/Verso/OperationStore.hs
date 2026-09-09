{- | The running server's derived operation catalogue (RFC-0028).

The operation log remains the source of truth. 'openOperationStore' reads and
fully evaluates it before publishing a store, and later reads use only the held
'MVar'.
-}
module Verso.OperationStore (
    OperationStore,
    openOperationStore,
    uncachedOperationStore,
    readOperations,
    appendOperation,
    nextSeq,
) where

import qualified Control.Concurrent.MVar as MVar
import qualified Verso.OperationLog as OperationLog

-- | A fully evaluated in-memory catalogue and its durable append-only log.
data OperationStore
    = WarmOperationStore FilePath (MVar.MVar [OperationLog.Operation])
    | UncachedOperationStore FilePath

-- | Opens the durable log once and publishes its operations as a warm catalogue.
openOperationStore :: FilePath -> IO OperationStore
openOperationStore logPath = do
    operations <- OperationLog.readOperations logPath
    forceOperations operations `seq` fmap (WarmOperationStore logPath) (MVar.newMVar operations)

-- | Builds the live-log adapter used by direct route tests.
uncachedOperationStore :: FilePath -> OperationStore
uncachedOperationStore = UncachedOperationStore

-- | Returns the held operations in append order without reading the durable log.
readOperations :: OperationStore -> IO [OperationLog.Operation]
readOperations (WarmOperationStore _ operations) = MVar.readMVar operations
readOperations (UncachedOperationStore logPath) = OperationLog.readOperations logPath

-- | Appends durably, then publishes the same operation to in-memory readers.
appendOperation :: OperationStore -> OperationLog.Operation -> IO ()
appendOperation (WarmOperationStore logPath operations) operation =
    MVar.modifyMVar_ operations $ \current -> do
        OperationLog.appendOperation logPath operation
        forceOperations [operation] `seq` pure (current ++ [operation])
appendOperation (UncachedOperationStore logPath) operation = OperationLog.appendOperation logPath operation

-- | Returns one past the largest held sequence number, or zero for an empty store.
nextSeq :: OperationStore -> IO Int
nextSeq store = do
    operations <- readOperations store
    pure (if null operations then 0 else maximum (map OperationLog.opSeq operations) + 1)

-- | Forces every operation field so parsing is paid before the server starts.
forceOperations :: [OperationLog.Operation] -> ()
forceOperations = foldr forceOperation ()
  where
    forceOperation operation rest =
        length (OperationLog.renderOperation operation) `seq` rest
