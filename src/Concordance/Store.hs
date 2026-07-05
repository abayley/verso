{- | The Concordance chunk store (RFC-0034): LanceDB behind the C shim.
Upserts replace a page's chunks wholesale (idempotent), search is the
engine's native hybrid (vector + BM25 fused with reciprocal rank fusion),
and the page listing drives reconcile. Strings cross the FFI boundary as
UTF-8; hit and page records come back in a packed buffer the shim fills
(records separated by 0x1e, fields by 0x1f).

Like all shim calls, each store call blocks the whole MicroHs runtime for
its duration (sub-millisecond to a few milliseconds).
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

import qualified Concordance.Utf8 as Utf8
import qualified Data.List as List
import qualified Foreign.C.String as CStr
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable

foreign import ccall "concordance_shim.h cn_available" c_available :: IO Int
foreign import ccall "concordance_shim.h cn_store_open"
    c_storeOpen :: CStr.CString -> Int -> CStr.CString -> Int -> IO Int
foreign import ccall "concordance_shim.h cn_store_close" c_storeClose :: IO ()
foreign import ccall "concordance_shim.h cn_store_upsert"
    c_storeUpsert ::
        CStr.CString ->
        CStr.CString ->
        CStr.CString ->
        Int ->
        CStr.CString ->
        CStr.CString ->
        Ptr.Ptr Double ->
        CStr.CString ->
        Int ->
        IO Int
foreign import ccall "concordance_shim.h cn_store_delete"
    c_storeDelete :: CStr.CString -> CStr.CString -> Int -> IO Int
foreign import ccall "concordance_shim.h cn_store_optimize"
    c_storeOptimize :: CStr.CString -> Int -> IO Int
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

-- | An open store handle (the shim holds the actual connection).
newtype Store = Store
    { storeDims :: Int
    }

-- | One chunk to index: anchor, text, and its unit vector.
data StoreChunk = StoreChunk
    { storeChunkAnchor :: String
    , storeChunkText :: String
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
                else pure (Right (Store dims))

-- | Closes the shim's store connection.
closeStore :: IO ()
closeStore = c_storeClose

{- | Replaces all of a page's chunks with the given set (delete-then-add,
so re-upserting is idempotent whatever the previous chunk count).
-}
upsertPage ::
    Store -> String -> String -> String -> [StoreChunk] -> IO (Either String ())
upsertPage store pageId statFp contentFp chunks =
    withUtf8 pageId $ \pageC ->
        withUtf8 statFp $ \statC ->
            withUtf8 contentFp $ \contentC ->
                withUtf8 (packStrings (map storeChunkAnchor chunks)) $ \anchorsC ->
                    withUtf8 (packStrings (map storeChunkText chunks)) $ \textsC ->
                        withVectors store chunks $ \vecsC ->
                            Alloc.allocaBytes errBufSize $ \errC -> do
                                rc <-
                                    c_storeUpsert
                                        pageC
                                        statC
                                        contentC
                                        (length chunks)
                                        anchorsC
                                        textsC
                                        vecsC
                                        errC
                                        errBufSize
                                shimResult rc errC (const ())

-- | Removes all of a page's chunks.
deletePage :: Store -> String -> IO (Either String ())
deletePage _store pageId =
    withUtf8 pageId $ \pageC ->
        Alloc.allocaBytes errBufSize $ \errC -> do
            rc <- c_storeDelete pageC errC errBufSize
            shimResult rc errC (const ())

{- | Optimises the dataset: compacts the fragments the delete-then-add
upserts leave behind, prunes old versions, and folds fresh rows into the
vector and FTS indexes. When to call it is the worker's policy
('Verso.SearchQueue.optimiseDue').
-}
optimizeStore :: Store -> IO (Either String ())
optimizeStore _store =
    Alloc.allocaBytes errBufSize $ \errC -> do
        rc <- c_storeOptimize errC errBufSize
        shimResult rc errC (const ())

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

-- | Lists indexed pages with their fingerprints (deduplicated).
listPages :: Store -> IO (Either String [PageFingerprints])
listPages _store =
    Alloc.allocaBytes resultBufSize $ \outC ->
        Alloc.allocaBytes errBufSize $ \errC -> do
            rc <- c_storePages outC resultBufSize errC errBufSize
            if rc < 0
                then Left <$> CStr.peekCAString errC
                else Right . List.nub . parsePages <$> peekUtf8 outC

-- | Runs a UTF-8 encoded string through 'CStr.withCAString'.
withUtf8 :: String -> (CStr.CString -> IO a) -> IO a
withUtf8 = CStr.withCAString . Utf8.encodeUtf8

-- | Reads a NUL-terminated shim buffer back as decoded text.
peekUtf8 :: CStr.CString -> IO String
peekUtf8 = fmap Utf8.decodeUtf8 . CStr.peekCAString

{- | Packs strings for the shim: each UTF-8 encoded and NUL-terminated,
back to back ('CStr.withCAString' adds the final NUL).
-}
packStrings :: [String] -> String
packStrings = concatMap (\s -> Utf8.encodeUtf8 s ++ "\0")

-- | Lays the chunks' vectors out as one flat double array.
withVectors :: Store -> [StoreChunk] -> (Ptr.Ptr Double -> IO a) -> IO a
withVectors store chunks action =
    Alloc.allocaBytes (max 8 (length chunks * storeDims store * 8)) $ \vecsC -> do
        mapM_
            (uncurry (Storable.pokeElemOff vecsC))
            (zip [0 ..] (concatMap storeChunkVector chunks))
        action vecsC

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

-- | Splits on a separator character.
splitOn :: Char -> String -> [String]
splitOn sep s =
    case break (== sep) s of
        (piece, []) -> [piece]
        (piece, _ : rest) -> piece : splitOn sep rest
