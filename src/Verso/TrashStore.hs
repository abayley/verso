{- | The running server's derived trash catalogue (RFC-0028, phase 6).

The trash manifests and operation log remain the source of truth. 'openTrashStore'
reads them once at startup, enriches each manifest with its delete timestamp, orders
the result newest-first, and forces it before publishing the store. Request-time
reads use only the held 'MVar'. 'uncachedTrashStore' is the filesystem adapter used
by direct route tests; it preserves their old live-read behaviour without exposing
that choice to application handlers.
-}
module Verso.TrashStore (
    TrashEntry (..),
    TrashStore,
    openTrashStore,
    uncachedTrashStore,
    trashEntries,
    recordTrashEntry,
    forgetTrashEntry,
) where

import qualified Control.Concurrent.MVar as MVar
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Verso.OperationLog as OperationLog
import qualified Verso.OperationStore as OperationStore
import qualified Verso.TreeMove as TreeMove

-- | One restorable trash item, enriched with the timestamp of its delete operation.
data TrashEntry = TrashEntry
    { entryId :: String
    , entryPath :: String
    , entryKind :: String
    , entryDeletedAt :: String
    }
    deriving (Eq, Show)

-- | A warm production catalogue or the uncached filesystem adapter used by direct route tests.
data TrashStore
    = WarmTrashStore (MVar.MVar [TrashEntry])
    | UncachedTrashStore FilePath FilePath

-- | Builds and fully evaluates the catalogue from the durable trash state.
openTrashStore :: FilePath -> OperationStore.OperationStore -> IO TrashStore
openTrashStore trashRoot operationStore = do
    entries <- loadTrashEntries trashRoot operationStore
    forceEntries entries `seq` fmap WarmTrashStore (MVar.newMVar entries)

-- | A pure adapter that retains request-time filesystem reads for direct route tests.
uncachedTrashStore :: FilePath -> FilePath -> TrashStore
uncachedTrashStore = UncachedTrashStore

-- | Loads and enriches the durable trash state.
loadTrashEntries :: FilePath -> OperationStore.OperationStore -> IO [TrashEntry]
loadTrashEntries trashRoot operationStore = do
    manifests <- TreeMove.listTrash trashRoot
    operations <- OperationStore.readOperations operationStore
    let deletionTimestamps =
            Map.fromList
                [ (show (OperationLog.opSeq operation), OperationLog.opTs operation)
                | operation <- operations
                , OperationLog.opType operation == OperationLog.OpDelete
                ]
        entries =
            List.sortBy
                newestFirst
                [ TrashEntry entryId path kind (Maybe.fromMaybe "" (Map.lookup entryId deletionTimestamps))
                | (entryId, path, kind) <- manifests
                ]
    forceEntries entries `seq` pure entries

-- | Returns the held newest-first entries without filesystem or operation-log reads.
trashEntries :: TrashStore -> IO [TrashEntry]
trashEntries (WarmTrashStore entries) = MVar.readMVar entries
trashEntries (UncachedTrashStore trashRoot logPath) =
    loadTrashEntries trashRoot (OperationStore.uncachedOperationStore logPath)

-- | Adds or replaces one entry while preserving the newest-first invariant.
recordTrashEntry :: TrashStore -> TrashEntry -> IO ()
recordTrashEntry (WarmTrashStore entries) newEntry =
    MVar.modifyMVar_ entries $ \current -> do
        let updated = List.sortBy newestFirst (newEntry : filter ((/= entryId newEntry) . entryId) current)
        forceEntries updated `seq` pure updated
recordTrashEntry (UncachedTrashStore _ _) _ = pure ()

-- | Removes one entry after it has been restored or permanently deleted.
forgetTrashEntry :: TrashStore -> String -> IO ()
forgetTrashEntry (WarmTrashStore entries) removedId =
    MVar.modifyMVar_ entries (pure . filter ((/= removedId) . entryId))
forgetTrashEntry (UncachedTrashStore _ _) _ = pure ()

-- | Orders numeric operation ids descending; malformed ids sort behind valid ids.
newestFirst :: TrashEntry -> TrashEntry -> Ordering
newestFirst left right = compare (sequenceOf right) (sequenceOf left)

-- | The numeric operation id used for ordering, or @-1@ for a malformed id.
sequenceOf :: TrashEntry -> Int
sequenceOf entry
    | not (null identifier) && all Char.isDigit identifier = read identifier
    | otherwise = -1
  where
    identifier = entryId entry

-- | Forces every held string so manifest parsing is paid during startup.
forceEntries :: [TrashEntry] -> ()
forceEntries = foldr forceEntry ()
  where
    forceEntry entry rest =
        ( length (entryId entry)
            + length (entryPath entry)
            + length (entryKind entry)
            + length (entryDeletedAt entry)
        )
            `seq` rest
