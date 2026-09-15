{- | The Concordance chunk store (RFC-0034): LanceDB behind the C shim.
Upserts replace a page's chunks wholesale (idempotent), search is the
engine's native hybrid (vector + BM25 fused with reciprocal rank fusion),
and the page listing drives reconcile. Strings cross the FFI boundary as
UTF-8; hit and page records come back in a packed buffer the shim fills
(records separated by 0x1e, fields by 0x1f).

Store mutations (upsert, delete, optimise) run on the shim's worker thread
(ADR-0080): the submit copies its arguments and returns immediately, the
calling green thread parks on the completion pipe like any descriptor, and
the rest of the runtime keeps serving. A mutation can take from tens of
milliseconds to several seconds (optimise's version cleanup), which would
otherwise stall every request. Reads (search, listing) and embedding stay
synchronous: they are short, and queries are user-initiated.
-}
module Concordance.Store (
    Store,
    StoreChunk (..),
    Hit (..),
    PageFingerprints (..),
    searchAvailable,
    openStore,
    closeStore,
    upsertPage,
    deletePage,
    optimizeStore,
    searchStore,
    listPages,
) where

import qualified Control.Concurrent.MVar as MVar
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map.Strict as Map
import qualified Foreign.C.String as CStr
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable
import qualified MicroHttp.Utf8 as Utf8
import qualified System.IO.FD as FD

foreign import ccall "concordance_shim.h cn_available" c_available :: IO Int
foreign import ccall "concordance_shim.h cn_store_open"
    c_storeOpen :: CStr.CString -> Int -> CStr.CString -> Int -> IO Int
foreign import ccall "concordance_shim.h cn_store_close" c_storeClose :: IO ()
foreign import ccall "concordance_shim.h cn_store_search"
    c_storeSearch ::
        Ptr.Ptr Double ->
        Int ->
        CStr.CString ->
        Int ->
        CStr.CString ->
        Int ->
        CStr.CString ->
        Int ->
        IO Int
foreign import ccall "concordance_shim.h cn_store_pages"
    c_storePages :: CStr.CString -> Int -> CStr.CString -> Int -> IO Int
foreign import ccall "concordance_shim.h cn_async_fd" c_asyncFd :: IO Int
foreign import ccall "concordance_shim.h cn_async_upsert"
    c_asyncUpsert ::
        CStr.CString ->
        CStr.CString ->
        CStr.CString ->
        Int ->
        CStr.CString ->
        CStr.CString ->
        Ptr.Ptr Double ->
        IO Int
foreign import ccall "concordance_shim.h cn_async_delete"
    c_asyncDelete :: CStr.CString -> IO Int
foreign import ccall "concordance_shim.h cn_async_optimize" c_asyncOptimize :: IO Int
foreign import ccall "concordance_shim.h cn_async_collect"
    c_asyncCollect :: CStr.CString -> Int -> IO Int

{- | An open store handle (the shim holds the actual connection). The lock
serialises mutations across green threads -- the shim has one async job slot
-- and the descriptor is the shim's completion pipe (ADR-0080).
-}
data Store = Store
    { storeDims :: Int
    , storeAsyncFd :: Int
    , storeLock :: MVar.MVar ()
    }

-- | One chunk to index: anchor, text (UTF-8 bytes), and its unit vector.
data StoreChunk = StoreChunk
    { storeChunkAnchor :: String
    , storeChunkText :: BS.ByteString
    , storeChunkVector :: [Double]
    }

-- | One search hit.
data Hit = Hit
    { hitPage :: String
    , hitAnchor :: String
    , hitSeq :: Int
    , hitScore :: Double
    , hitText :: String
    }
    deriving (Eq, Show)

-- | A page's stored fingerprints, for reconcile.
data PageFingerprints = PageFingerprints
    { pageFpPage :: String
    , pageFpStat :: String
    , pageFpContent :: String
    }
    deriving (Eq, Show)

errBufSize :: Int
errBufSize = 512

-- | The result buffer for search hits and page listings.
resultBufSize :: Int
resultBufSize = 1024 * 1024

{- | The shim's CN_BUFFER_FULL: the out buffer was too small for the full
result, and the call may be retried with a larger one.
-}
bufferFullRc :: Int
bufferFullRc = -9

{- | The ceiling for 'listPages' buffer growth. The listing carries one
record per chunk row, so it scales with the corpus; at roughly 100 bytes
per row this admits several hundred thousand rows.
-}
maxPagesBufSize :: Int
maxPagesBufSize = 64 * 1024 * 1024

-- | Whether the real shim is linked (False means the stub: search off).
searchAvailable :: IO Bool
searchAvailable = (== 1) <$> c_available

-- | Opens (or creates) the Lance dataset at the directory.
openStore :: FilePath -> Int -> IO (Either String Store)
openStore dir dims =
    CStr.withCAString dir $ \dirC ->
        Alloc.allocaBytes errBufSize $ \errC -> do
            rc <- c_storeOpen dirC dims errC errBufSize
            if rc /= 0
                then Left <$> CStr.peekCAString errC
                else do
                    fd <- c_asyncFd
                    if fd < 0
                        then pure (Left "search store: async worker unavailable")
                        else do
                            lock <- MVar.newMVar ()
                            pure (Right (Store dims fd lock))

-- | Closes the shim's store connection.
closeStore :: IO ()
closeStore = c_storeClose

{- | Replaces all of a page's chunks with the given set (delete-then-add,
so re-upserting is idempotent whatever the previous chunk count).
-}
upsertPage ::
    Store -> String -> String -> String -> [StoreChunk] -> IO (Either String ())
upsertPage store pageId statFp contentFp chunks =
    -- the submit copies every argument, so the marshalling scopes end here
    mutate store $
        withUtf8 pageId $ \pageC ->
            withUtf8 statFp $ \statC ->
                withUtf8 contentFp $ \contentC ->
                    -- already UTF-8 bytes with NUL separators: CAString passes them through, where
                    -- withCString would encode each NUL as a two-byte sequence and lose the separators
                    CStr.withCAString (packStrings (map storeChunkAnchor chunks)) $ \anchorsC ->
                        withPackedBytes (map storeChunkText chunks) $ \textsC ->
                            withVectors store chunks $ \vecsC ->
                                c_asyncUpsert
                                    pageC
                                    statC
                                    contentC
                                    (length chunks)
                                    anchorsC
                                    textsC
                                    vecsC

-- | Removes all of a page's chunks.
deletePage :: Store -> String -> IO (Either String ())
deletePage store pageId =
    mutate store (withUtf8 pageId c_asyncDelete)

{- | Optimises the dataset: compacts the fragments the delete-then-add
upserts leave behind, prunes old versions, and folds fresh rows into the
vector and FTS indexes. When to call it is the worker's policy
('Verso.SearchQueue.optimiseDue').
-}
optimizeStore :: Store -> IO (Either String ())
optimizeStore store =
    mutate store c_asyncOptimize

-- | Hybrid search: query vector plus query text, top k fused hits.
searchStore :: Store -> [Double] -> String -> Int -> IO (Either String [Hit])
searchStore store queryVec queryText k =
    Alloc.allocaBytes (storeDims store * 8) $ \vecC ->
        withUtf8 queryText $ \textC ->
            Alloc.allocaBytes resultBufSize $ \outC ->
                Alloc.allocaBytes errBufSize $ \errC -> do
                    mapM_
                        (uncurry (Storable.pokeElemOff vecC))
                        (zip [0 ..] queryVec)
                    rc <-
                        c_storeSearch
                            vecC
                            (storeDims store)
                            textC
                            k
                            outC
                            resultBufSize
                            errC
                            errBufSize
                    if rc < 0
                        then Left <$> CStr.peekCAString errC
                        else Right . parseHits <$> peekUtf8 outC

{- | Lists indexed pages with their fingerprints (deduplicated). The
listing has one record per chunk row, so its size scales with the corpus;
when a buffer overflows the call retries with double the size, up to
'maxPagesBufSize'.
-}
listPages :: Store -> IO (Either String [PageFingerprints])
listPages _store = go resultBufSize
  where
    go bufSize =
        Alloc.allocaBytes bufSize $ \outC ->
            Alloc.allocaBytes errBufSize $ \errC -> do
                rc <- c_storePages outC bufSize errC errBufSize
                if rc == bufferFullRc && bufSize * 2 <= maxPagesBufSize
                    then go (bufSize * 2)
                    else
                        if rc < 0
                            then Left <$> CStr.peekCAString errC
                            else Right . dedupePages . parsePages <$> peekUtf8 outC

-- | Passes a string to the shim as UTF-8 ('CStr.withCString' encodes in the runtime).
withUtf8 :: String -> (CStr.CString -> IO a) -> IO a
withUtf8 = CStr.withCString

-- | Reads a NUL-terminated shim buffer back as decoded text ('CStr.peekCString' decodes in the runtime).
peekUtf8 :: CStr.CString -> IO String
peekUtf8 = CStr.peekCString

{- | Packs strings for the shim: each UTF-8 encoded and NUL-terminated,
back to back ('CStr.withCAString' adds the final NUL).
-}
packStrings :: [String] -> String
packStrings = concatMap (\s -> Utf8.encodeUtf8 s ++ "\0")

{- | As 'packStrings' for byte strings already in UTF-8 (the chunk texts):
each NUL-terminated, back to back, with no decode\/re-encode round trip
('BS.useAsCString' copies once and adds the final NUL).
-}
withPackedBytes :: [BS.ByteString] -> (CStr.CString -> IO a) -> IO a
withPackedBytes texts = BS.useAsCString (BS.concat (concatMap (\t -> [t, nulByte]) texts))

nulByte :: BS.ByteString
nulByte = BS.pack "\0"

-- | Lays the chunks' vectors out as one flat double array.
withVectors :: Store -> [StoreChunk] -> (Ptr.Ptr Double -> IO a) -> IO a
withVectors store chunks action =
    Alloc.allocaBytes (max 8 (length chunks * storeDims store * 8)) $ \vecsC -> do
        mapM_
            (uncurry (Storable.pokeElemOff vecsC))
            (zip [0 ..] (concatMap storeChunkVector chunks))
        action vecsC

{- | Runs a store mutation off-thread (ADR-0080): submits the job to the
shim's worker, parks this green thread on the completion descriptor (the
rest of the runtime keeps running), then collects the outcome. The lock
serialises green threads over the shim's single job slot.
-}
mutate :: Store -> IO Int -> IO (Either String ())
mutate store submit =
    MVar.withMVar (storeLock store) $ \_ -> do
        rc <- submit
        if rc < 0
            then pure (Left "search store: async submit refused")
            else do
                FD.waitForReadFD (storeAsyncFd store)
                Alloc.allocaBytes errBufSize $ \errC -> do
                    collected <- c_asyncCollect errC errBufSize
                    shimResult collected errC (const ())

-- | Interprets a shim return code, reading the error buffer on failure.
shimResult :: Int -> CStr.CString -> (Int -> a) -> IO (Either String a)
shimResult rc errC ok
    | rc < 0 = Left <$> CStr.peekCAString errC
    | otherwise = pure (Right (ok rc))

-- | Splits a packed record buffer on the record and field separators.
records :: String -> [[String]]
records buf =
    [splitOn '\x1f' r | r <- splitOn '\x1e' buf, not (null r)]

-- | Parses search-hit records: page, anchor, seq, score, text.
parseHits :: String -> [Hit]
parseHits buf =
    [ Hit page anchor (read seqStr) (read scoreStr) text
    | [page, anchor, seqStr, scoreStr, text] <- records buf
    ]

-- | Parses page-listing records: page, stat fingerprint, content fingerprint.
parsePages :: String -> [PageFingerprints]
parsePages buf =
    [PageFingerprints page statFp contentFp | [page, statFp, contentFp] <- records buf]

{- | Keeps each page's first record. The listing repeats a page once per
chunk row, so this must not be quadratic ('Data.List.nub' was): the real
corpus lists tens of thousands of rows.
-}
dedupePages :: [PageFingerprints] -> [PageFingerprints]
dedupePages = go Map.empty
  where
    go _ [] = []
    go seen (p : rest)
        | Map.member (pageFpPage p) seen = go seen rest
        | otherwise = p : go (Map.insert (pageFpPage p) () seen) rest

-- | Splits on a separator character.
splitOn :: Char -> String -> [String]
splitOn sep s =
    case break (== sep) s of
        (piece, []) -> [piece]
        (piece, _ : rest) -> piece : splitOn sep rest
