module ForkFfiSpike (main) where

import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Monad as Monad
import qualified Foreign.C.String as CStr
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Storable as Storable
import qualified Foreign.Ptr as Ptr
import qualified System.IO as IO

foreign import ccall "cn_shim.h cn_embed_init" c_embedInit :: CStr.CString -> Int -> Int -> Int -> IO Int
foreign import ccall "cn_shim.h cn_embed" c_embed :: Ptr.Ptr Int -> Int -> Ptr.Ptr Double -> IO Int

main :: IO ()
main = do
    IO.hSetBuffering IO.stdout IO.LineBuffering
    let model = "../reference/models/Xenova/bge-small-en-v1.5/onnx/model_quantized.onnx"
    rc <- CStr.withCAString model $ \m -> c_embedInit m 1 384 1
    putStrLn ("init rc=" ++ show rc)
    done <- MVar.newEmptyMVar
    _ <- Concurrent.forkIO $ do
        Alloc.allocaBytes (64 * 8) $ \ids -> Alloc.allocaBytes (384 * 8) $ \out -> do
            Monad.forM_ [0 .. 63] $ \i -> Storable.pokeElemOff ids i (2000 + i)
            Monad.forM_ [1 .. 20 :: Int] $ \n -> do
                r <- c_embed ids 64 out
                putStrLn ("worker embed " ++ show n ++ " rc=" ++ show r)
                Concurrent.yield
        MVar.putMVar done ()
    Monad.forM_ [1 .. 200 :: Int] $ \_ -> Concurrent.yield
    MVar.takeMVar done
    putStrLn "OK"
