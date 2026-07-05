module ForkNoop (main) where

import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.MVar as MVar
import qualified System.IO as IO

foreign import ccall "cn_shim.h cn_noop" c_noop :: Int -> IO Int

main :: IO ()
main = do
    IO.hSetBuffering IO.stdout IO.NoBuffering
    r0 <- c_noop 1
    putStrLn ("main noop: " ++ show r0)
    done <- MVar.newEmptyMVar
    _ <- Concurrent.forkIO $ do
        putStrLn "worker: alive"
        r <- c_noop 41
        putStrLn ("worker noop: " ++ show r)
        MVar.putMVar done ()
    MVar.takeMVar done
    putStrLn "OK"
