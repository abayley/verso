{- | The running server's home for the link index (RFC-0029, revised). The graph
('Verso.LinkIndex') lives in an 'MVar', built at startup and then read by move/delete
with __no per-operation filesystem walk__: the server owns the document tree, so the only
routine out-of-band writer is the periodic re-export, which calls 'refreshLinkIndex'
explicitly. In-server mutations keep the in-memory graph correct incrementally -- a move
is a pure prefix relocation ('relocateInIndex'), a delete/save/create/restore re-reads
only the few paths it touched ('applyChanges' / 'removeSubtreeInIndex' /
'addSubtreeToIndex'). None of these walk or re-parse the whole tree (ADR-0067 as amended).

The index is __persisted__ (the resolved edges plus the @(path, mtime, size)@
fingerprint) to a file. 'openLinkIndex' loads it and trusts it only when its fingerprint
still matches the tree (one startup stat-walk); otherwise it rebuilds and re-persists.
The persisted file is rewritten on build and refresh, not per mutation, so in-server
mutations stay snappy; a file made stale by mutations is simply rebuilt on the next
start. A missing or corrupt file rebuilds too.
-}
module Verso.LinkIndexStore (
    LinkIndexStore,
    newLinkIndexStore,
    openLinkIndex,
    refreshLinkIndex,
    currentIndex,
    applyChanges,
    relocateInIndex,
    removeSubtreeInIndex,
    addSubtreeToIndex,
    scanPageLinks,
) where

import qualified Control.Concurrent.MVar as MVar
import qualified Control.Exception as Exception
import qualified Control.Monad as Monad
import qualified Control.Monad.Except as Except
import qualified Control.Monad.IO.Class as Class
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Bytes as Bytes
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import qualified Verso.DocumentLinks as DocumentLinks
import qualified Verso.LinkFingerprint as LinkFingerprint
import qualified Verso.LinkIndex as LinkIndex

-- | The graph and the fingerprint of the tree it was built from, held together.
data IndexState = IndexState
    { stIndex :: LinkIndex.LinkIndex
    , stFingerprint :: LinkFingerprint.Fingerprint
    }

-- | A handle to the server's link index ('Nothing' until 'openLinkIndex' builds or loads it).
newtype LinkIndexStore = LinkIndexStore (MVar.MVar (Maybe IndexState))

-- | A fresh, unopened store.
newLinkIndexStore :: IO LinkIndexStore
newLinkIndexStore = fmap LinkIndexStore (MVar.newMVar Nothing)

{- | The current graph, read without any filesystem access (RFC-0029). Empty if the
store was never opened (a misconfiguration; move/delete then simply find no candidates).
-}
currentIndex :: LinkIndexStore -> IO LinkIndex.LinkIndex
currentIndex (LinkIndexStore mv) = fmap (maybe LinkIndex.emptyIndex stIndex) (MVar.readMVar mv)

{- | Opens the index at startup: load the persisted file and trust it only if its
fingerprint still matches the tree (one stat-walk); otherwise build from the tree. Either
way the result is persisted and held. The build is forced so its cost is paid here, not
in the first move/delete.
-}
openLinkIndex :: FilePath -> FilePath -> LinkIndexStore -> IO (Either String ())
openLinkIndex root indexPath store = Except.runExceptT $ do
    loaded <- loadValidState root indexPath
    st <- case loaded of
        Just s -> pure s
        Nothing -> do
            built <- buildFromTree root
            persistState indexPath built
            pure built
    Class.liftIO (storeState store st)

-- | Rebuilds the index from the tree and re-persists it (the explicit refresh after a re-export).
refreshLinkIndex :: FilePath -> FilePath -> LinkIndexStore -> IO (Either String ())
refreshLinkIndex root indexPath store = Except.runExceptT $ do
    built <- buildFromTree root
    persistState indexPath built
    Class.liftIO (storeState store built)

{- | Incremental maintenance for an in-server mutation: re-read each given @.md@ path and
patch the graph -- 'updatePage' when it now exists, 'removePage' when it is gone. No walk,
no re-parse, not persisted. The reads happen before the lock so a vanished file is a
'Left', not a thrown exception; the pure patch then runs under the lock.
-}
applyChanges :: FilePath -> [String] -> LinkIndexStore -> IO (Either String ())
applyChanges root paths store = Except.runExceptT $ do
    pairs <- tryIO (mapM readPath paths)
    Class.liftIO (modifyIndex store (\ix -> List.foldl' patch ix pairs))
  where
    readPath rel = do links <- scanPageLinks (root ++ "/" ++ rel); pure (rel, links)
    patch ix (rel, Nothing) = LinkIndex.removePage rel ix
    patch ix (rel, Just links) = LinkIndex.updatePageLinks rel links ix

-- | Maintenance for a move: relocate the moved subtree's keys and targets in-place (a pure transform, no re-read, cannot fail).
relocateInIndex :: String -> String -> LinkIndexStore -> IO ()
relocateInIndex oldPrefix newPrefix store = modifyIndex store (LinkIndex.relocateIndex oldPrefix newPrefix)

-- | Maintenance for a section delete: drop every page at or under the deleted prefix (pure, cannot fail).
removeSubtreeInIndex :: String -> LinkIndexStore -> IO ()
removeSubtreeInIndex prefix store = modifyIndex store (LinkIndex.removeSubtree prefix)

-- | Maintenance for a section restore: re-read every @.md@ now present under the restored prefix and add it.
addSubtreeToIndex :: FilePath -> String -> LinkIndexStore -> IO (Either String ())
addSubtreeToIndex root prefix store = Except.runExceptT $ do
    files <- tryIO (LinkFingerprint.markdownFiles root)
    let under = [(rel, fs) | (rel, fs) <- files, rel == prefix || (prefix ++ "/") `List.isPrefixOf` rel]
    pairs <- tryIO (mapM readBoth under)
    Class.liftIO (modifyIndex store (\ix -> List.foldl' add ix pairs))
  where
    readBoth (rel, fs) = do links <- scanPageLinks fs; pure (rel, links)
    add ix (rel, links) = LinkIndex.updatePageLinks rel (Maybe.fromMaybe [] links) ix

-- | Runs an IO action that may throw, converting any exception to a 'Left' message (the Either boundary).
tryIO :: IO a -> Except.ExceptT String IO a
tryIO action = Except.ExceptT (fmap (either (Left . showErr) Right) (Exception.try action))
  where
    showErr e = show (e :: Exception.SomeException)

-- | Applies a pure graph transform to the held state under the lock, forcing the result. A no-op before the index is opened.
modifyIndex :: LinkIndexStore -> (LinkIndex.LinkIndex -> LinkIndex.LinkIndex) -> IO ()
modifyIndex (LinkIndexStore mv) f = MVar.modifyMVar_ mv (forceApply f)

-- | The pure graph transform applied to one held state, forced so the parse is paid here, not on the next read.
forceApply :: (LinkIndex.LinkIndex -> LinkIndex.LinkIndex) -> Maybe IndexState -> IO (Maybe IndexState)
forceApply _ Nothing = pure Nothing
forceApply f (Just st) =
    let forced = LinkIndex.forceIndex (f (stIndex st))
     in forced `seq` pure (Just st{stIndex = forced})

-- | Replaces the held state (after a build or load).
storeState :: LinkIndexStore -> IndexState -> IO ()
storeState (LinkIndexStore mv) st = MVar.modifyMVar_ mv (\_ -> pure (Just st))

{- | Builds the graph and fingerprint from the tree in a single walk (forced), so the
whole-tree parse is paid here, not lazily in the first request. Each page is scanned as a
stream and its links folded into the graph before the next is opened, so the build holds
one chunk of one document plus the growing index, never the corpus (RFC-0039).
Filesystem exceptions become 'Left' via 'tryIO'.
-}
buildFromTree :: FilePath -> Except.ExceptT String IO IndexState
buildFromTree root = do
    files <- tryIO (LinkFingerprint.markdownFiles root)
    (graph, fingerprint) <- tryIO (Monad.foldM scanAndStat (LinkIndex.emptyIndex, Map.empty) files)
    let forced = LinkIndex.forceIndex graph
    forced `seq` pure (IndexState forced fingerprint)
  where
    scanAndStat (ix, fp) (rel, fs) = do
        links <- scanPageLinks fs
        st <- FileSystem.fileStat fs
        let ix' = case links of
                Just ls -> length ls `seq` LinkIndex.updatePageLinks rel ls ix
                Nothing -> ix
            fp' = either (const fp) (\s -> Map.insert rel s fp) st
        ix' `seq` pure (ix', fp')

{- | A page's links, scanned as a stream in 'scanChunkBytes' chunks so the body is never
resident whole; 'Nothing' when the file is absent or cannot be opened.
-}
scanPageLinks :: FilePath -> IO (Maybe [DocumentLinks.Link])
scanPageLinks fs = do
    outcome <- Stream.fileEnumeratorChunked scanChunkBytes fs DocumentLinks.linksI >>= Iteratee.run
    pure (either (const Nothing) Just outcome)

-- | The chunk size for scanning a document's links (RFC-0039: sized for document scanning, not socket traffic).
scanChunkBytes :: Int
scanChunkBytes = 65536

-- Persistence -----------------------------------------------------------------

{- | Loads the persisted index and returns it only if its stored fingerprint still
matches the tree (one stat-walk). 'Nothing' when the file is absent, corrupt, or stale.
-}
loadValidState :: FilePath -> FilePath -> Except.ExceptT String IO (Maybe IndexState)
loadValidState root indexPath = do
    exists <- tryIO (Directory.doesFileExist indexPath)
    if not exists
        then pure Nothing
        else do
            -- folded a line at a time (RFC-0043): the index grows with the corpus and is never held whole
            folded <- tryIO (Stream.foldFileLines collectRow (Just []) indexPath)
            case folded of
                Right (Just rows) -> do
                    -- Force the loaded graph here so the Map/inbound construction is paid at load,
                    -- not deferred to the first move/delete (forceIndex walks both adjacency maps).
                    let graph = LinkIndex.forceIndex (edgesToIndex rows)
                        storedFp = rowsToFingerprint rows
                    current <- tryIO (LinkFingerprint.fingerprintTree root)
                    if storedFp == current
                        then pure (graph `seq` Just (IndexState graph storedFp))
                        else pure Nothing
                -- unreadable or corrupt: rebuilt from the tree
                _ -> pure Nothing

-- | Writes the index to a temp file then atomically renames it into place, so a partial write never corrupts it.
persistState :: FilePath -> IndexState -> Except.ExceptT String IO ()
persistState indexPath st = do
    let tmp = indexPath ++ ".tmp"
    -- RFC-0040 phase 8: write the rows one line at a time, so the ~1.2MB index is never built as a whole
    -- String (a ~24x spike) nor a whole-file BS.concat. Byte-identical to the previous unlines form.
    written <- tryIO (Stream.writeFileLines tmp (stateLines st))
    case written of
        Left e -> do
            -- A failed persist leaves nothing behind: the temp is removed, and the
            -- rebuild on the next start serves as the recovery (RFC-0040).
            _ <- tryIO (FileSystem.removeFilePath tmp)
            Except.throwError (show e)
        Right () -> pure ()
    _ <- tryIO (FileSystem.renamePath tmp indexPath) -- best-effort; a failed persist just means a rebuild next start
    pure ()

{- | The index as line-oriented rows, one 'ByteString' per line, lazily: @E\<TAB>page\<TAB>target...@ for
each page's edges (a linkless page is just @E\<TAB>page@), then @F\<TAB>path\<TAB>sec\<TAB>nsec\<TAB>size@
for each fingerprint entry. Tree paths contain no tabs. 'Stream.writeFileLines' appends the newline after
each, so this is byte-identical to the old @unlines@-then-@BS.pack@ whole-index form.
-}
stateLines :: IndexState -> [BS.ByteString]
stateLines st = map BS.pack (edgeLines ++ fpLines)
  where
    edgeLines = [List.intercalate "\t" ("E" : page : targets) | (page, targets) <- LinkIndex.outboundEdges (stIndex st)]
    fpLines =
        [ List.intercalate "\t" ["F", path, show (FileSystem.fsMtimeSec s), show (FileSystem.fsMtimeNsec s), show (FileSystem.fsSize s)]
        | (path, s) <- Map.toList (stFingerprint st)
        ]

{- | The line step of the index load: parses one row onto the accumulator, or
marks the file corrupt ('Nothing', which the loader treats as a rebuild) on the
first malformed line. Fields are split with 'Bytes.split', a strict index scan
over O(1) views (the library's @BS.split@ unpacks the line; 'MicroHttp.Bytes').
Rows accumulate in reverse; the graph and fingerprint map are order-insensitive.
-}
collectRow :: Maybe [Row] -> BS.ByteString -> IO (Maybe [Row])
collectRow acc line
    | BS.null line = pure acc
    | otherwise = pure (acc >>= \rows -> fmap (: rows) (parseRow (map BS.unpack (Bytes.split '\t' line))))

-- | Reconstructs the graph from the edge rows (re-deriving the inverse), no body re-parse.
edgesToIndex :: [Row] -> LinkIndex.LinkIndex
edgesToIndex entries = LinkIndex.indexFromEdges [(page, targets) | EdgeRow page targets <- entries]

-- | The stored fingerprint map from the fingerprint rows.
rowsToFingerprint :: [Row] -> LinkFingerprint.Fingerprint
rowsToFingerprint entries = Map.fromList [(path, s) | FpRow path s <- entries]

-- | One parsed persistence row: an edge list for a page, or a fingerprint entry.
data Row = EdgeRow String [String] | FpRow String FileSystem.FileStat

-- | Parses one tab-split row into a 'Row'; 'Nothing' when the tag or arity is unrecognised.
parseRow :: [String] -> Maybe Row
parseRow ("E" : page : targets) = Just (EdgeRow page targets)
parseRow ["F", path, sec, nsec, size] =
    case (readInt sec, readInt nsec, readInt size) of
        (Just a, Just b, Just c) -> Just (FpRow path (FileSystem.FileStat a b c))
        _ -> Nothing
parseRow _ = Nothing

-- | A total integer parse.
readInt :: String -> Maybe Int
readInt s = case reads s of
    [(n, "")] -> Just n
    _ -> Nothing
