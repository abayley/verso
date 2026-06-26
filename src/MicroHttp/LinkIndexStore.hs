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
import Control.Exception (SomeException, try)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
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
openLinkIndex :: FilePath -> FilePath -> LinkIndexStore -> IO (Either String ())
openLinkIndex root indexPath store = runExceptT $ do
    loaded <- loadValidState root indexPath
    st <- case loaded of
        Just s -> pure s
        Nothing -> do
            built <- buildFromTree root
            persistState indexPath built
            pure built
    liftIO (storeState store st)

-- | Rebuilds the index from the tree and re-persists it (the explicit refresh after a re-export).
refreshLinkIndex :: FilePath -> FilePath -> LinkIndexStore -> IO (Either String ())
refreshLinkIndex root indexPath store = runExceptT $ do
    built <- buildFromTree root
    persistState indexPath built
    liftIO (storeState store built)

{- | Incremental maintenance for an in-server mutation: re-read each given @.md@ path and
patch the graph -- 'updatePage' when it now exists, 'removePage' when it is gone. No walk,
no re-parse, not persisted. The reads happen before the lock so a vanished file is a
'Left', not a thrown exception; the pure patch then runs under the lock.
-}
applyChanges :: FilePath -> [String] -> LinkIndexStore -> IO (Either String ())
applyChanges root paths store = runExceptT $ do
    pairs <- tryIO (mapM readPath paths)
    liftIO (modifyIndex store (\ix -> foldl' patch ix pairs))
  where
    readPath rel = do body <- readPageBody (root ++ "/" ++ rel); pure (rel, body)
    patch ix (rel, Nothing) = removePage rel ix
    patch ix (rel, Just body) = updatePage rel body ix

-- | Maintenance for a move: relocate the moved subtree's keys and targets in-place (a pure transform, no re-read, cannot fail).
relocateInIndex :: String -> String -> LinkIndexStore -> IO ()
relocateInIndex oldPrefix newPrefix store = modifyIndex store (relocateIndex oldPrefix newPrefix)

-- | Maintenance for a section delete: drop every page at or under the deleted prefix (pure, cannot fail).
removeSubtreeInIndex :: String -> LinkIndexStore -> IO ()
removeSubtreeInIndex prefix store = modifyIndex store (removeSubtree prefix)

-- | Maintenance for a section restore: re-read every @.md@ now present under the restored prefix and add it.
addSubtreeToIndex :: FilePath -> String -> LinkIndexStore -> IO (Either String ())
addSubtreeToIndex root prefix store = runExceptT $ do
    files <- tryIO (markdownFiles root)
    let under = [(rel, fs) | (rel, fs) <- files, rel == prefix || (prefix ++ "/") `isPrefixOf` rel]
    pairs <- tryIO (mapM readBoth under)
    liftIO (modifyIndex store (\ix -> foldl' add ix pairs))
  where
    readBoth (rel, fs) = do body <- readPageBody fs; pure (rel, body)
    add ix (rel, body) = updatePage rel (fromMaybe BS.empty body) ix

-- | Runs an IO action that may throw, converting any exception to a 'Left' message (the Either boundary).
tryIO :: IO a -> ExceptT String IO a
tryIO action = ExceptT (fmap (either (Left . showErr) Right) (try action))
  where
    showErr e = show (e :: SomeException)

-- | Applies a pure graph transform to the held state under the lock, forcing the result. A no-op before the index is opened.
modifyIndex :: LinkIndexStore -> (LinkIndex -> LinkIndex) -> IO ()
modifyIndex (LinkIndexStore mv) f = modifyMVar_ mv (forceApply f)

-- | The pure graph transform applied to one held state, forced so the parse is paid here, not on the next read.
forceApply :: (LinkIndex -> LinkIndex) -> Maybe IndexState -> IO (Maybe IndexState)
forceApply _ Nothing = pure Nothing
forceApply f (Just st) =
    let forced = forceIndex (f (stIndex st))
     in forced `seq` pure (Just st{stIndex = forced})

-- | Replaces the held state (after a build or load).
storeState :: LinkIndexStore -> IndexState -> IO ()
storeState (LinkIndexStore mv) st = modifyMVar_ mv (\_ -> pure (Just st))

{- | Builds the graph and fingerprint from the tree in a single walk (forced), so the
whole-tree parse is paid here, not lazily in the first request. Filesystem exceptions
become 'Left' via 'tryIO'.
-}
buildFromTree :: FilePath -> ExceptT String IO IndexState
buildFromTree root = do
    files <- tryIO (markdownFiles root)
    entries <- tryIO (mapM readAndStat files)
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
loadValidState :: FilePath -> FilePath -> ExceptT String IO (Maybe IndexState)
loadValidState root indexPath = do
    exists <- tryIO (doesFileExist indexPath)
    if not exists
        then pure Nothing
        else do
            bytes <- tryIO (BS.readFile indexPath)
            case parseState bytes of
                Nothing -> pure Nothing
                Just st -> do
                    current <- tryIO (fingerprintTree root)
                    pure (if stFingerprint st == current then Just st else Nothing)

-- | Writes the index to a temp file then atomically renames it into place, so a partial write never corrupts it.
persistState :: FilePath -> IndexState -> ExceptT String IO ()
persistState indexPath st = do
    let tmp = indexPath ++ ".tmp"
    tryIO (BS.writeFile tmp (serialiseState st))
    _ <- tryIO (renamePath tmp indexPath) -- best-effort; a failed persist just means a rebuild next start
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
