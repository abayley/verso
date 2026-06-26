{- | The running server's home for the link index (RFC-0029, revised). The graph
('MicroHttp.LinkIndex') lives in an 'MVar', built at startup and then read by move/delete
with __no per-operation filesystem walk__: the server owns the document tree, so the only
routine out-of-band writer is the periodic re-export, which calls 'refreshLinkIndex'
explicitly. In-server mutations keep the in-memory graph correct incrementally -- a move
is a pure prefix relocation ('relocateInIndex'), a delete/save/create/restore re-reads
only the few paths it touched ('applyChanges' / 'removeSubtreeInIndex' /
'addSubtreeToIndex'). None of these walk or re-parse the whole tree (ADR-067 as amended).

The index is __persisted__ (the resolved edges plus the @(path, mtime, size)@
fingerprint) to a file. 'openLinkIndex' loads it and trusts it only when its fingerprint
still matches the tree (one startup stat-walk); otherwise it rebuilds and re-persists.
The persisted file is rewritten on build and refresh, not per mutation, so in-server
mutations stay snappy; a file made stale by mutations is simply rebuilt on the next
start. A missing or corrupt file rebuilds too.
-}
module MicroHttp.LinkIndexStore (
    LinkIndexStore,
    newLinkIndexStore,
    openLinkIndex,
    refreshLinkIndex,
    currentIndex,
    applyChanges,
    relocateInIndex,
    removeSubtreeInIndex,
    addSubtreeToIndex,
) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Monad (foldM)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.List (foldl', intercalate, isPrefixOf)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing)
import MicroHttp.FileOps (FileStat (..), fileStat, renamePath)
import MicroHttp.LinkFingerprint (Fingerprint, fingerprintTree, markdownFiles)
import MicroHttp.LinkIndex (
    LinkIndex,
    emptyIndex,
    forceIndex,
    indexFromEdges,
    outboundEdges,
    relocateIndex,
    removePage,
    removeSubtree,
    updatePage,
 )
import System.Directory (doesFileExist)

-- | The graph and the fingerprint of the tree it was built from, held together.
data IndexState = IndexState
    { stIndex :: LinkIndex
    , stFingerprint :: Fingerprint
    }

-- | A handle to the server's link index ('Nothing' until 'openLinkIndex' builds or loads it).
newtype LinkIndexStore = LinkIndexStore (MVar (Maybe IndexState))

-- | A fresh, unopened store.
newLinkIndexStore :: IO LinkIndexStore
newLinkIndexStore = fmap LinkIndexStore (newMVar Nothing)

{- | The current graph, read without any filesystem access (RFC-0029). Empty if the
store was never opened (a misconfiguration; move/delete then simply find no candidates).
-}
currentIndex :: LinkIndexStore -> IO LinkIndex
currentIndex (LinkIndexStore mv) = fmap (maybe emptyIndex stIndex) (readMVar mv)

{- | Opens the index at startup: load the persisted file and trust it only if its
fingerprint still matches the tree (one stat-walk); otherwise build from the tree. Either
way the result is persisted and held. The build is forced so its cost is paid here, not
in the first move/delete.
-}
openLinkIndex :: FilePath -> FilePath -> LinkIndexStore -> IO ()
openLinkIndex root indexPath (LinkIndexStore mv) =
    modifyMVar_ mv $ \_ -> do
        loaded <- loadValidState root indexPath
        case loaded of
            Just st -> pure (Just st)
            Nothing -> do
                st <- buildFromTree root
                persistState indexPath st
                pure (Just st)

-- | Rebuilds the index from the tree and re-persists it (the explicit refresh after a re-export).
refreshLinkIndex :: FilePath -> FilePath -> LinkIndexStore -> IO ()
refreshLinkIndex root indexPath (LinkIndexStore mv) =
    modifyMVar_ mv $ \_ -> do
        st <- buildFromTree root
        persistState indexPath st
        pure (Just st)

{- | Incremental maintenance for an in-server mutation: re-read each given @.md@ path and
patch the graph -- 'updatePage' when it now exists, 'removePage' when it is gone. No walk,
no re-parse of the tree. Not persisted (the file is rewritten only on build/refresh).
-}
applyChanges :: FilePath -> [String] -> LinkIndexStore -> IO ()
applyChanges root paths = onIndex (\ix -> foldM (patchOne root) ix paths)

-- | Maintenance for a move: relocate the moved subtree's keys and targets in-place (a pure transform, no re-read).
relocateInIndex :: String -> String -> LinkIndexStore -> IO ()
relocateInIndex oldPrefix newPrefix = onIndexPure (relocateIndex oldPrefix newPrefix)

-- | Maintenance for a section delete: drop every page at or under the deleted prefix.
removeSubtreeInIndex :: String -> LinkIndexStore -> IO ()
removeSubtreeInIndex prefix = onIndexPure (removeSubtree prefix)

-- | Maintenance for a section restore: re-read every @.md@ now present under the restored prefix and add it.
addSubtreeToIndex :: FilePath -> String -> LinkIndexStore -> IO ()
addSubtreeToIndex root prefix store = do
    files <- markdownFiles root
    let under = [(rel, fs) | (rel, fs) <- files, rel == prefix || (prefix ++ "/") `isPrefixOf` rel]
    onIndex (\ix -> foldM addOne ix under) store
  where
    addOne ix (rel, fs) = do
        body <- readPageBody fs
        pure (updatePage rel (fromMaybe BS.empty body) ix)

-- | Applies an IO graph transform under the lock, forcing the result.
onIndex :: (LinkIndex -> IO LinkIndex) -> LinkIndexStore -> IO ()
onIndex f (LinkIndexStore mv) = modifyMVar_ mv (onIndexState f)

-- | Transforms one held state's graph (a no-op before the index is opened), forcing the result.
onIndexState :: (LinkIndex -> IO LinkIndex) -> Maybe IndexState -> IO (Maybe IndexState)
onIndexState _ Nothing = pure Nothing
onIndexState f (Just st) = do
    ix <- f (stIndex st)
    let forced = forceIndex ix
    forced `seq` pure (Just st{stIndex = forced})

-- | Applies a pure graph transform under the lock, forcing the result.
onIndexPure :: (LinkIndex -> LinkIndex) -> LinkIndexStore -> IO ()
onIndexPure f = onIndex (pure . f)

-- | Re-reads one path and patches it into the graph (update if present, remove if gone).
patchOne :: FilePath -> LinkIndex -> String -> IO LinkIndex
patchOne root ix rel = do
    body <- readPageBody (root ++ "/" ++ rel)
    pure (maybe (removePage rel ix) (\b -> updatePage rel b ix) body)

{- | Builds the graph and fingerprint from the tree in a single walk (forced), so the
whole-tree parse is paid here, not lazily in the first request.
-}
buildFromTree :: FilePath -> IO IndexState
buildFromTree root = do
    files <- markdownFiles root
    entries <- mapM readAndStat files
    let pages = [(rel, body) | (rel, Just body, _) <- entries]
        fingerprint = Map.fromList [(rel, st) | (rel, _, Just st) <- entries]
        graph = forceIndex (buildFromBodies pages)
    graph `seq` pure (IndexState graph fingerprint)
  where
    readAndStat (rel, fs) = do
        body <- readPageBody fs
        st <- fileStat fs
        pure (rel, body, st)

-- | Builds the graph from page bodies (the parse), via repeated 'updatePage' over the empty index.
buildFromBodies :: [(String, ByteString)] -> LinkIndex
buildFromBodies = foldl' (\ix (rel, body) -> updatePage rel body ix) emptyIndex

-- | Reads a page body as 'ByteString' (no @String@ conversion), or 'Nothing' when absent.
readPageBody :: FilePath -> IO (Maybe ByteString)
readPageBody fs = do
    exists <- doesFileExist fs
    if exists then fmap Just (BS.readFile fs) else pure Nothing

-- Persistence -----------------------------------------------------------------

{- | Loads the persisted index and returns it only if its stored fingerprint still
matches the tree (one stat-walk). 'Nothing' when the file is absent, corrupt, or stale.
-}
loadValidState :: FilePath -> FilePath -> IO (Maybe IndexState)
loadValidState root indexPath = do
    exists <- doesFileExist indexPath
    if not exists
        then pure Nothing
        else do
            bytes <- BS.readFile indexPath
            case parseState bytes of
                Nothing -> pure Nothing
                Just st -> do
                    current <- fingerprintTree root
                    pure (if stFingerprint st == current then Just st else Nothing)

-- | Writes the index to a temp file then atomically renames it into place, so a partial write never corrupts it.
persistState :: FilePath -> IndexState -> IO ()
persistState indexPath st = do
    let tmp = indexPath ++ ".tmp"
    BS.writeFile tmp (serialiseState st)
    _ <- renamePath tmp indexPath -- best-effort; a failed persist just means a rebuild next start
    pure ()

{- | Serialises the index as line-oriented text: @E\<TAB>page\<TAB>target...@ for each
page's edges (a linkless page is just @E\<TAB>page@), then
@F\<TAB>path\<TAB>sec\<TAB>nsec\<TAB>size@ for each fingerprint entry. Tree paths contain
no tabs.
-}
serialiseState :: IndexState -> ByteString
serialiseState st = BS.pack (unlines (edgeLines ++ fpLines))
  where
    edgeLines = [intercalate "\t" ("E" : page : targets) | (page, targets) <- outboundEdges (stIndex st)]
    fpLines =
        [ intercalate "\t" ["F", path, show (fsMtimeSec s), show (fsMtimeNsec s), show (fsSize s)]
        | (path, s) <- Map.toList (stFingerprint st)
        ]

-- | Parses a serialised index; 'Nothing' if any line is malformed (treated as corrupt -> rebuild).
parseState :: ByteString -> Maybe IndexState
parseState bytes =
    let rows = map (map BS.unpack . BS.split '\t') (filter (not . BS.null) (BS.lines bytes))
        parsed = map parseRow rows
     in if any isNothing parsed
            then Nothing
            else Just (assemble (catMaybes parsed))
  where
    assemble entries =
        IndexState
            (indexFromEdges [(page, targets) | EdgeRow page targets <- entries])
            (Map.fromList [(path, s) | FpRow path s <- entries])

-- | One parsed persistence row: an edge list for a page, or a fingerprint entry.
data Row = EdgeRow String [String] | FpRow String FileStat

parseRow :: [String] -> Maybe Row
parseRow ("E" : page : targets) = Just (EdgeRow page targets)
parseRow ["F", path, sec, nsec, size] =
    case (readInt sec, readInt nsec, readInt size) of
        (Just a, Just b, Just c) -> Just (FpRow path (FileStat a b c))
        _ -> Nothing
parseRow _ = Nothing

-- | A total integer parse.
readInt :: String -> Maybe Int
readInt s = case reads s of
    [(n, "")] -> Just n
    _ -> Nothing
