{- | The Verso side of Concordance search (RFC-0034): the re-index worker
draining the coalescing queue on a green thread, freshness reconciliation
against the document tree, and the query path with its small vector cache.

The worker yields to the scheduler between chunk embeds, because every
shim call blocks the whole MicroHs runtime (~30 ms per chunk with the
default profile): a large backlog costs stutter, never a freeze.

Structural mutations (move/delete/restore/undo) enqueue a 'reconcileToken'
alongside the directly affected pages: the worker then runs a stat-tier
sweep that catches every page the mutation rewrote (referrers whose links
changed, parent index.md listings) without the handlers having to
enumerate them (RFC-0034 decision 14's three populations).
-}
module Verso.SearchIndex (
    SearchConfig (..),
    SearchRuntime,
    startSearch,
    enqueuePage,
    enqueueReconcile,
    searchDepth,
    searchQuery,
) where

import qualified Concordance.Embedding as Embedding
import qualified Concordance.Fingerprint as Fingerprint
import qualified Concordance.Fuse as Fuse
import qualified Concordance.Store as Store
import qualified Concordance.Utf8 as Utf8
import qualified Concordance.WordPiece as WordPiece
import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory
import qualified Verso.LinkFingerprint as LinkFingerprint
import qualified Verso.SearchChunks as SearchChunks
import qualified Verso.SearchQueue as SearchQueue

-- | Everything 'startSearch' needs, supplied by the application.
data SearchConfig = SearchConfig
    { searchRoot :: FilePath
    -- ^ The document tree root.
    , searchIndexDir :: FilePath
    -- ^ The Lance dataset directory.
    , searchModelId :: String
    {- ^ The configured model identity; a mismatch with the stored one
    invalidates the whole index (RFC-0034 decision 13).
    -}
    , searchProfile :: Embedding.Profile
    , searchVocabPath :: FilePath
    , searchTitleOf :: String -> String -> String
    {- ^ A page's display title from its tree path and raw content
    (injected: the frontmatter machinery lives with the application).
    -}
    , searchLog :: String -> IO ()
    }

-- | The live search state: engine handles, queue, and query cache.
data SearchRuntime = SearchRuntime
    { srConfig :: SearchConfig
    , srStore :: Store.Store
    , srEmbedder :: Embedding.Embedder
    , srVocab :: WordPiece.Vocab
    , srQueue :: MVar.MVar SearchQueue.Queue
    , srWake :: MVar.MVar ()
    , srQueryCache :: IORef.IORef [(String, [Double])]
    , srWritesSinceOptimise :: IORef.IORef Int
    }

-- | The queue entry that triggers a reconcile sweep (never a tree path).
reconcileToken :: String
reconcileToken = "\0reconcile"

-- | The chunker's size cap in characters (~ the 384-token embed cap).
chunkCapChars :: Int
chunkCapChars = 1500

-- | Recent query vectors kept for re-searches.
queryCacheSize :: Int
queryCacheSize = 32

{- | Brings search up: opens the embedder, vocabulary, and store, forks the
worker, and enqueues the startup reconcile. 'Nothing' (with a log line)
when the shim is the stub or any piece fails -- the server runs on with
search disabled.
-}
startSearch :: SearchConfig -> IO (Maybe SearchRuntime)
startSearch cfg = do
    available <- Store.searchAvailable
    if not available
        then do
            searchLog cfg "search: shim not built; search disabled"
            pure Nothing
        else do
            modelOk <- checkModelId cfg
            openedEmbedder <- Embedding.openEmbedder (searchProfile cfg)
            case openedEmbedder of
                Left e -> do
                    searchLog cfg ("search: embedder unavailable (" ++ e ++ "); search disabled")
                    pure Nothing
                Right embedder -> do
                    vocabBytes <- BS.readFile (searchVocabPath cfg)
                    openedStore <- Store.openStore (searchIndexDir cfg) (Embedding.profileDims (searchProfile cfg))
                    case openedStore of
                        Left e -> do
                            searchLog cfg ("search: store unavailable (" ++ e ++ "); search disabled")
                            pure Nothing
                        Right store -> do
                            queue <- MVar.newMVar SearchQueue.emptyQueue
                            wake <- MVar.newMVar ()
                            cache <- IORef.newIORef []
                            writes <- IORef.newIORef 0
                            let runtime =
                                    SearchRuntime
                                        { srConfig = cfg
                                        , srStore = store
                                        , srEmbedder = embedder
                                        , srVocab = WordPiece.mkVocab vocabBytes
                                        , srQueue = queue
                                        , srWake = wake
                                        , srQueryCache = cache
                                        , srWritesSinceOptimise = writes
                                        }
                            Monad.unless modelOk (wipeIndex runtime)
                            _ <- Concurrent.forkIO (workerLoop runtime)
                            enqueueReconcile runtime
                            searchLog cfg "search: enabled"
                            pure (Just runtime)

{- | Compares the configured model id with the one recorded beside the
index; a mismatch means every stored vector is invalid. Records the
configured id either way.
-}
checkModelId :: SearchConfig -> IO Bool
checkModelId cfg = do
    let marker = searchIndexDir cfg ++ "/model-id"
    Directory.createDirectoryIfMissing True (searchIndexDir cfg)
    exists <- Directory.doesFileExist marker
    stored <- if exists then readFile marker else pure ""
    writeFile marker (searchModelId cfg)
    pure (not exists || stored == searchModelId cfg)

-- | Drops every indexed page (model changed: full rebuild via reconcile).
wipeIndex :: SearchRuntime -> IO ()
wipeIndex runtime = do
    searchLog (srConfig runtime) "search: model changed; rebuilding the index"
    listed <- Store.listPages (srStore runtime)
    case listed of
        Left e -> searchLog (srConfig runtime) ("search: wipe failed (" ++ e ++ ")")
        Right pages -> mapM_ (Store.deletePage (srStore runtime) . Store.pageFpPage) pages

-- | Queues one page for re-indexing (publish, create, restore hooks).
enqueuePage :: SearchRuntime -> String -> IO ()
enqueuePage runtime page = do
    MVar.modifyMVar_ (srQueue runtime) (pure . SearchQueue.enqueue page)
    wakeWorker runtime

{- | Queues a reconcile sweep (startup, index refresh, and after every
structural mutation, whose link rewrites touch pages no handler lists).
-}
enqueueReconcile :: SearchRuntime -> IO ()
enqueueReconcile runtime = do
    MVar.modifyMVar_ (srQueue runtime) (pure . SearchQueue.enqueue reconcileToken)
    wakeWorker runtime

-- | Pages awaiting or undergoing re-indexing (the results-note count).
searchDepth :: SearchRuntime -> IO Int
searchDepth runtime = SearchQueue.queueDepth <$> MVar.readMVar (srQueue runtime)

-- | Signals the worker that the queue has work.
wakeWorker :: SearchRuntime -> IO ()
wakeWorker runtime = Monad.void (MVar.tryPutMVar (srWake runtime) ())

-- | The worker green thread: drain the queue, then sleep until woken.
workerLoop :: SearchRuntime -> IO ()
workerLoop runtime = do
    MVar.takeMVar (srWake runtime)
    drain
    workerLoop runtime
  where
    drain = do
        next <- MVar.modifyMVar (srQueue runtime) (pure . swap . SearchQueue.startNext)
        case next of
            Nothing -> pure ()
            Just item -> do
                processItem runtime item
                MVar.modifyMVar_ (srQueue runtime) (pure . SearchQueue.finish)
                optimiseIfDue runtime
                Concurrent.yield
                drain
    swap (a, b) = (b, a)

{- | Optimises the store when the policy says so (RFC-0034/ADR-075 follow-up;
'SearchQueue.optimiseDue'): as soon as the queue drains in normal operation,
and in batches during a bulk backlog. The delete-then-add upserts fragment
the Lance dataset, and optimisation also folds fresh rows into the vector
and FTS indexes.
-}
optimiseIfDue :: SearchRuntime -> IO ()
optimiseIfDue runtime = do
    writes <- IORef.readIORef (srWritesSinceOptimise runtime)
    depth <- searchDepth runtime
    Monad.when (SearchQueue.optimiseDue writes (depth == 0)) $ do
        result <- Store.optimizeStore (srStore runtime)
        IORef.writeIORef (srWritesSinceOptimise runtime) 0
        case result of
            Left e -> searchLog (srConfig runtime) ("search: optimise failed: " ++ e)
            Right () ->
                searchLog
                    (srConfig runtime)
                    ("search: optimised store after " ++ show writes ++ " write(s)")

-- | Counts one store write towards the optimisation policy.
countWrite :: SearchRuntime -> IO ()
countWrite runtime = IORef.modifyIORef' (srWritesSinceOptimise runtime) (+ 1)

-- | One work item: a page re-index, or the reconcile sweep.
processItem :: SearchRuntime -> String -> IO ()
processItem runtime item
    | item == reconcileToken = reconcile runtime
    | otherwise = indexPage runtime item

{- | Re-indexes one page: read, chunk, embed (yielding between chunks),
upsert; a page gone from the tree (ENOENT) is deleted from the store instead.
Any other stat failure -- EACCES, EIO -- means the page may well still exist,
so its store entry is left alone and the failure is logged; deleting on a
transient fault would silently drop the page from search until its next edit.
Failures log and move on -- the next reconcile retries them.
-}
indexPage :: SearchRuntime -> String -> IO ()
indexPage runtime path = do
    let cfg = srConfig runtime
        fsPath = searchRoot cfg ++ "/" ++ path
    stat <- FileSystem.fileStat fsPath
    case stat of
        Left e
            | FileSystem.isDoesNotExist e -> do
                result <- Store.deletePage (srStore runtime) path
                countWrite runtime
                report cfg path (fmap (const "deleted") result)
            | otherwise -> report cfg path (Left ("stat failed (" ++ show e ++ ")"))
        Right fileStat -> do
            bytes <- BS.readFile fsPath
            let content = Utf8.decodeUtf8 (BS.unpack bytes)
                title = searchTitleOf cfg path content
                chunks = SearchChunks.chunkPage chunkCapChars title content
            embedded <- mapM (embedChunk runtime) chunks
            case sequence embedded of
                Left e -> report cfg path (Left e)
                Right storeChunks -> do
                    result <-
                        Store.upsertPage
                            (srStore runtime)
                            path
                            (statFingerprint fileStat)
                            (Fingerprint.contentFingerprint bytes)
                            storeChunks
                    countWrite runtime
                    report cfg path (fmap (const (show (length chunks) ++ " chunks")) result)
  where
    report cfg page (Left e) = searchLog cfg ("search: index " ++ page ++ " failed: " ++ e)
    report cfg page (Right what) = searchLog cfg ("search: indexed " ++ page ++ " (" ++ what ++ ")")

-- | Embeds one chunk, yielding to the scheduler around the blocking call.
embedChunk :: SearchRuntime -> SearchChunks.Chunk -> IO (Either String Store.StoreChunk)
embedChunk runtime chunk = do
    Concurrent.yield
    embedded <-
        Embedding.embedText
            (srEmbedder runtime)
            (srVocab runtime)
            (searchProfile (srConfig runtime))
            (SearchChunks.chunkText chunk)
    pure
        ( Store.StoreChunk
            (SearchChunks.chunkAnchor chunk)
            (SearchChunks.chunkText chunk)
            <$> embedded
        )

-- | A page's stat fingerprint string: seconds, nanoseconds, size.
statFingerprint :: FileSystem.FileStat -> String
statFingerprint s =
    show (FileSystem.fsMtimeSec s)
        ++ ":"
        ++ show (FileSystem.fsMtimeNsec s)
        ++ ":"
        ++ show (FileSystem.fsSize s)

{- | The stat-tier reconcile sweep (RFC-0034 decision 5): stat every page,
read-and-hash only those whose stat changed, enqueue only real content
changes and missing pages, and delete store entries for vanished pages.
-}
reconcile :: SearchRuntime -> IO ()
reconcile runtime = do
    let cfg = srConfig runtime
    listed <- Store.listPages (srStore runtime)
    case listed of
        Left e -> searchLog cfg ("search: reconcile failed (" ++ e ++ ")")
        Right stored -> do
            files <- LinkFingerprint.markdownFiles (searchRoot cfg)
            let storedMap =
                    Map.fromList
                        [(Store.pageFpPage p, p) | p <- stored]
            changed <- Monad.filterM (needsReindex runtime storedMap) files
            let treePaths = map fst files
                orphans = [p | p <- Map.keys storedMap, p `notElem` treePaths]
            mapM_ (\orphan -> Store.deletePage (srStore runtime) orphan >> countWrite runtime) orphans
            mapM_ (enqueuePage runtime . fst) changed
            searchLog
                cfg
                ( "search: reconcile enqueued "
                    ++ show (length changed)
                    ++ " page(s), removed "
                    ++ show (length orphans)
                    ++ " orphan(s)"
                )

{- | Whether a page needs re-indexing: unknown to the store, or stat
changed and the content hash disagrees.
-}
needsReindex ::
    SearchRuntime -> Map.Map String Store.PageFingerprints -> (String, FilePath) -> IO Bool
needsReindex runtime storedMap (treePath, fsPath) =
    case Map.lookup treePath storedMap of
        Nothing -> pure True
        Just entry -> do
            stat <- FileSystem.fileStat fsPath
            case stat of
                -- a page vanishing mid-sweep (ENOENT) is a normal race; any
                -- other errno is a real fault, logged so a persistent EACCES
                -- is not invisible. Either way there is nothing to re-index.
                Left e -> do
                    Monad.unless (FileSystem.isDoesNotExist e) $
                        searchLog
                            (srConfig runtime)
                            ("search: reconcile stat " ++ treePath ++ " failed (" ++ show e ++ ")")
                    pure False
                Right fileStat
                    | statFingerprint fileStat == Store.pageFpStat entry -> pure False
                    | otherwise -> do
                        bytes <- BS.readFile fsPath
                        Concurrent.yield
                        pure
                            ( Fingerprint.contentFingerprint bytes
                                /= Store.pageFpContent entry
                            )

{- | Answers a search: embed the query (skipping the embed on a cache hit),
run the engine's hybrid search, and collapse to one hit per page. The
caller renders excerpts and the pending-count note.
-}
searchQuery :: SearchRuntime -> String -> Int -> IO (Either String [Store.Hit])
searchQuery runtime query k = do
    let cfg = srConfig runtime
        profile = searchProfile cfg
        prefixed = Embedding.profileQueryPrefix profile ++ query
    cached <- lookup query <$> IORef.readIORef (srQueryCache runtime)
    vec <- case cached of
        Just v -> pure (Right v)
        Nothing -> do
            embedded <- Embedding.embedText (srEmbedder runtime) (srVocab runtime) profile prefixed
            case embedded of
                Right v ->
                    IORef.modifyIORef'
                        (srQueryCache runtime)
                        (take queryCacheSize . ((query, v) :))
                        >> pure (Right v)
                left -> pure left
    case vec of
        Left e -> pure (Left e)
        Right v -> do
            hits <- Store.searchStore (srStore runtime) v query k
            pure (fmap (List.take k . Fuse.groupByPage) hits)
