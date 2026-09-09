{- | Measures the iteratee send path against a plain sendAll baseline, under a
saturated two-process harness (a GHC blocking drainer keeps the pipe empty,
so the send throughput, not the non-blocking poll, is what gets measured).
The MicroHs side is the subject here: it listens, accepts one connection per
method, sends a fixed volume, and reports MB/s, so the iteratee egress
overhead is the delta from the plain-sendAll row measured in the same binary:

  * plain sendAll    - the raw sendAll loop, no iteratee (reference);
  * iteratee egress  - a chunked body enumerator driven into socketSinkI
    (the streaming egress machinery).

Run via scripts/egress-bench.sh or `make bench-egress`.
-}
module Main (main) where

import qualified Data.ByteString as BS
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import MicroHttp.Iteratee (Enumerator, Iter (..), Stream (..), run)
import MicroHttp.Network.Socket
import MicroHttp.Stream (socketSinkI)
import System.IO (BufferMode (..), hSetBuffering, stdout)

listenPort :: Port
listenPort = Port 8090

-- | Bytes per response-body chunk fed to the sink.
chunkBytes :: Int
chunkBytes = 65536

totalBytes :: Int
totalBytes = 512 * 1024 * 1024

-- | The response-body payload, built once and shared.
payload :: BS.ByteString
payload = BS.replicate chunkBytes 0x78

methods :: [(String, ClientSocket -> IO Int)]
methods =
    [ ("plain sendAll  ", plainSend)
    , ("iteratee egress", iterateeSend)
    ]

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    opened <- listenTcp HostAny listenPort 1
    case opened of
        Left err -> error ("listenTcp failed: " ++ show err)
        Right socket -> do
            putStrLn "egress sender: listening on 8090"
            putStrLn "method          | MB/s"
            mapM_ (measure socket) methods
            _ <- closeListenSocket socket
            return ()

measure :: ListenSocket -> (String, ClientSocket -> IO Int) -> IO ()
measure socket (label, method) = do
    accepted <- accept socket
    case accepted of
        Left err -> error ("accept failed: " ++ show err)
        Right client -> do
            start <- getCurrentTime
            sent <- method client
            end <- getCurrentTime
            let seconds = realToFrac (diffUTCTime end start) :: Double
            putStrLn (label ++ " | " ++ showRounded (fromIntegral sent / 1000000 / seconds))
            _ <- closeClientSocket client
            return ()

-- | The raw sendAll loop, no iteratee: the reference throughput.
plainSend :: ClientSocket -> IO Int
plainSend client = go totalBytes
  where
    go remaining
        | remaining <= 0 = return totalBytes
        | otherwise = do
            let n = min remaining chunkBytes
            sent <- sendAll client (BS.take n payload)
            case sent of
                Left err -> error ("sendAll failed: " ++ show err)
                Right () -> go (remaining - n)

{- | A chunked body enumerator driven into socketSinkI: the streaming egress
machinery (enumerator, socketSinkI, the IterM send steps).
-}
iterateeSend :: ClientSocket -> IO Int
iterateeSend client = do
    final <- chunkedEnumerator payload totalBytes (socketSinkI client)
    result <- run final
    case result of
        Left err -> error ("egress failed: " ++ show err)
        Right () -> return totalBytes

{- | Feeds a fixed chunk repeatedly until @total@ bytes are delivered, then end
of stream; the shape a streaming response body (or fileEnumerator) takes.
-}
chunkedEnumerator :: BS.ByteString -> Int -> Enumerator e a
chunkedEnumerator chunk = loop
  where
    loop remaining it = case it of
        NeedInput k
            | remaining <= 0 -> return (k (EndOfStream Nothing))
            | otherwise ->
                let n = min remaining (BS.length chunk)
                 in loop (remaining - n) (k (Chunk (BS.take n chunk)))
        IterM m -> m >>= loop remaining
        _ -> return it

showRounded :: Double -> String
showRounded x = show (fromIntegral (round (x * 10) :: Int) / 10 :: Double)
