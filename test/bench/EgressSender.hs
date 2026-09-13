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
import qualified Data.Time.Clock as Clock
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Stream as Stream
import qualified System.IO as IO

listenPort :: Socket.Port
listenPort = Socket.Port 8090

-- | Bytes per response-body chunk fed to the sink.
chunkBytes :: Int
chunkBytes = 65536

totalBytes :: Int
totalBytes = 512 * 1024 * 1024

-- | The response-body payload, built once and shared.
payload :: BS.ByteString
payload = BS.replicate chunkBytes 0x78

methods :: [(String, Socket.ClientSocket -> IO Int)]
methods =
    [ ("plain sendAll  ", plainSend)
    , ("iteratee egress", iterateeSend)
    ]

main :: IO ()
main = do
    IO.hSetBuffering IO.stdout IO.LineBuffering
    opened <- Socket.listenTcp Socket.HostAny listenPort 1
    case opened of
        Left err -> error ("listenTcp failed: " ++ show err)
        Right socket -> do
            putStrLn "egress sender: listening on 8090"
            putStrLn "method          | MB/s"
            mapM_ (measure socket) methods
            _ <- Socket.closeListenSocket socket
            return ()

measure :: Socket.ListenSocket -> (String, Socket.ClientSocket -> IO Int) -> IO ()
measure socket (label, method) = do
    accepted <- Socket.accept socket
    case accepted of
        Left err -> error ("accept failed: " ++ show err)
        Right (client, _) -> do
            start <- Clock.getCurrentTime
            sent <- method client
            end <- Clock.getCurrentTime
            let seconds = realToFrac (Clock.diffUTCTime end start) :: Double
            putStrLn (label ++ " | " ++ showRounded (fromIntegral sent / 1000000 / seconds))
            _ <- Socket.closeClientSocket client
            return ()

-- | The raw Socket.sendAll loop, no iteratee: the reference throughput.
plainSend :: Socket.ClientSocket -> IO Int
plainSend client = go totalBytes
  where
    go remaining
        | remaining <= 0 = return totalBytes
        | otherwise = do
            let n = min remaining chunkBytes
            sent <- Socket.sendAll client (BS.take n payload)
            case sent of
                Left err -> error ("sendAll failed: " ++ show err)
                Right () -> go (remaining - n)

{- | A chunked body enumerator driven into Stream.socketSinkI: the streaming egress
machinery (enumerator, Stream.socketSinkI, the Iteratee.IterM send steps).
-}
iterateeSend :: Socket.ClientSocket -> IO Int
iterateeSend client = do
    final <- chunkedEnumerator payload totalBytes (Stream.socketSinkI client)
    result <- Iteratee.run final
    case result of
        Left err -> error ("egress failed: " ++ show err)
        Right () -> return totalBytes

{- | Feeds a fixed chunk repeatedly until @total@ bytes are delivered, then end
of stream; the shape a streaming response body (or fileEnumerator) takes.
-}
chunkedEnumerator :: BS.ByteString -> Int -> Iteratee.Enumerator e a
chunkedEnumerator chunk = loop
  where
    loop remaining it = case it of
        Iteratee.NeedInput k
            | remaining <= 0 -> return (k (Iteratee.EndOfStream Nothing))
            | otherwise ->
                let n = min remaining (BS.length chunk)
                 in loop (remaining - n) (k (Iteratee.Chunk (BS.take n chunk)))
        Iteratee.IterM m -> m >>= loop remaining
        _ -> return it

showRounded :: Double -> String
showRounded x = show (fromIntegral (round (x * 10) :: Int) / 10 :: Double)
