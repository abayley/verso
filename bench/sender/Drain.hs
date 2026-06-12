{- | The drain side of the egress bench: a GHC blocking receiver that connects
to the MicroHs sender and reads to end of stream as fast as it can, keeping
the pipe empty so the sender's send throughput (not the non-blocking poll)
is what gets measured. The MicroHs sender reports the result.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import Network.Socket
import Network.Socket.ByteString (recv)
import System.Environment (getArgs)

recvChunk :: Int
recvChunk = 65536

main :: IO ()
main = do
    args <- getArgs
    let (host, port) = case args of
            [p] -> ("127.0.0.1", p)
            _ -> ("127.0.0.1", "8090")
    infos <- getAddrInfo (Just defaultHints{addrSocketType = Stream}) (Just host) (Just port)
    case infos of
        [] -> ioError (userError "no address info for sender")
        info : _ -> do
            sock <- connectRetry info 200
            drain sock
            close sock

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

drain :: Socket -> IO ()
drain sock = do
    bytes <- recv sock recvChunk
    if BS.null bytes then return () else drain sock
