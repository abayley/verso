{- | A blocking-socket load generator (GHC) for the socket saturation bench.
It connects to the MicroHs receiver and sends a fixed volume as fast as the
receiver can drain it. Using the network package's blocking sendAll (which
parks the thread on the IO manager rather than busy-polling) is the point:
it keeps the pipe full without the sender hitting the receiver's 1 ms poll,
so the receiver's recv throughput is what gets measured.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import Network.Socket
import Network.Socket.ByteString (sendAll)
import System.Environment (getArgs)

chunkBytes :: Int
chunkBytes = 65536

main :: IO ()
main = do
    args <- getArgs
    let (host, port, total) = case args of
            [p, b] -> ("127.0.0.1", p, read b)
            _ -> ("127.0.0.1", "8090", 512 * 1024 * 1024)
    infos <- getAddrInfo (Just defaultHints{addrSocketType = Stream}) (Just host) (Just port)
    case infos of
        [] -> ioError (userError "no address info for receiver")
        info : _ -> do
            sock <- connectRetry info 200
            sendN sock (BS.replicate chunkBytes 0x78) total
            close sock

{- | Connects with a fresh socket per attempt, retrying past the startup race
where the receiver is not yet listening.
-}
connectRetry :: AddrInfo -> Int -> IO Socket
connectRetry info attempts = do
    sock <- openSocket info
    result <- try (connect sock (addrAddress info)) :: IO (Either SomeException ())
    case result of
        Right () -> return sock
        Left err -> do
            close sock
            if attempts <= 0
                then ioError (userError ("connect failed: " ++ show err))
                else do
                    threadDelay 20000
                    connectRetry info (attempts - 1)

sendN :: Socket -> BS.ByteString -> Int -> IO ()
sendN sock chunk remaining
    | remaining <= 0 = return ()
    | otherwise = do
        let n = min remaining (BS.length chunk)
        sendAll sock (BS.take n chunk)
        sendN sock chunk (remaining - n)
