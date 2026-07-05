{- | RFC-0034 phase 0 spike: call the search shim from MicroHs and measure
call latencies from inside the interpreter -- raw FFI overhead (no-op),
embedding (short query and full chunk), and a LanceDB vector search against
the dataset written by store_spike. Compares against the C-side timings in
docs/design/search-spike-notes.md so the interpreter marshalling cost is the
delta.
-}
module FfiSpike (main) where

import qualified Control.Monad as Monad
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import qualified Foreign.C.String as CStr
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable

foreign import ccall "cn_shim.h cn_noop" c_noop :: Int -> IO Int
foreign import ccall "cn_shim.h cn_embed_init" c_embedInit :: CStr.CString -> Int -> Int -> Int -> IO Int
foreign import ccall "cn_shim.h cn_embed" c_embed :: Ptr.Ptr Int -> Int -> Ptr.Ptr Double -> IO Int
foreign import ccall "cn_shim.h cn_embed_close" c_embedClose :: IO ()
foreign import ccall "cn_shim.h cn_store_open" c_storeOpen :: CStr.CString -> CStr.CString -> IO Int
foreign import ccall "cn_shim.h cn_store_search" c_storeSearch :: Ptr.Ptr Double -> Int -> Int -> Ptr.Ptr Double -> IO Int
foreign import ccall "cn_shim.h cn_store_close" c_storeClose :: IO ()

-- | Times an action's repetitions and returns milliseconds per call.
timePerCall :: Int -> IO () -> IO Double
timePerCall reps act = do
    start <- getCurrentTime
    Monad.replicateM_ reps act
    end <- getCurrentTime
    let seconds = realToFrac (diffUTCTime end start) :: Double
    pure (seconds * 1000 / fromIntegral reps)

-- | A synthetic BERT-ish token sequence: [CLS], filler ids, [SEP].
fillIds :: Ptr.Ptr Int -> Int -> IO ()
fillIds buf n = do
    Storable.pokeElemOff buf 0 101
    Monad.forM_ [1 .. n - 2] $ \i -> Storable.pokeElemOff buf i (2000 + i)
    Storable.pokeElemOff buf (n - 1) 102

embedBench :: String -> Int -> Int -> IO ()
embedBench label ntok reps =
    Alloc.allocaBytes (ntok * 8) $ \ids ->
        Alloc.allocaBytes (384 * 8) $ \out -> do
            fillIds ids ntok
            _ <- c_embed ids ntok out -- warm-up
            ms <- timePerCall reps (Monad.void (c_embed ids ntok out))
            v0 <- Storable.peekElemOff out 0
            putStrLn (label ++ ": " ++ show ms ++ " ms/call (v0=" ++ show v0 ++ ")")

main :: IO ()
main = do
    -- raw FFI overhead
    nres <- c_noop 41
    nms <- timePerCall 100000 (Monad.void (c_noop 1))
    putStrLn ("noop: " ++ show (nms * 1000000) ++ " ns/call (result " ++ show nres ++ ")")

    -- embedding: bge-small int8, CLS pooling, 4 threads
    let model = "../reference/models/Xenova/bge-small-en-v1.5/onnx/model_quantized.onnx"
    initRc <- CStr.withCAString model $ \m -> c_embedInit m 1 384 4
    putStrLn ("embed init: rc=" ++ show initRc)
    embedBench "embed 32 tokens" 32 50
    embedBench "embed 384 tokens" 384 20
    c_embedClose

    -- store: vector search against the store_spike dataset (dims 4)
    openRc <- CStr.withCAString "/tmp/lancedb-spike" $ \d ->
        CStr.withCAString "chunks" $ \t -> c_storeOpen d t
    putStrLn ("store open: rc=" ++ show openRc)
    Alloc.allocaBytes (4 * 8) $ \vec ->
        Alloc.allocaBytes 8 $ \dist -> do
            Monad.forM_ [0 .. 3] $ \d ->
                Storable.pokeElemOff vec d (if d == (1 :: Int) then 1.0 else 0.0 :: Double)
            hits <- c_storeSearch vec 4 2 dist
            best <- Storable.peek dist
            putStrLn ("search hits=" ++ show hits ++ " best _distance=" ++ show best)
            ms <- timePerCall 50 (Monad.void (c_storeSearch vec 4 2 dist))
            putStrLn ("vector search k=2: " ++ show ms ++ " ms/call")
    c_storeClose
