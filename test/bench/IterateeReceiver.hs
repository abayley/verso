{- | Measures the iteratee receive path against a plain recv baseline, under
the same saturated two-process harness as the socket bench (a GHC blocking
sender keeps the pipe full). For each consumer it accepts one connection,
drains the stream, and reports MB/s, so the iteratee overhead is the delta
from the plain-recv row measured in the same binary:

  * plain recv      - the raw recv loop, no iteratee (reference);
  * iteratee stream - socketEnumerator into a counting sink (the pure
    streaming machinery: bind, continuations, residue threading).

Both consumers are constant-memory, which is the path the question "can the
iteratee keep up with the socket data" is about. Strict accumulation
(readBodyStrict) is deliberately not benched here at this volume: the server
caps bodies at settingsMaxBodyBytes (1 MB by default), so materialising a
512 MB body is an anti-pattern that simply exhausts memory.

Run via scripts/iteratee-bench.sh or `make bench-iteratee`.
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

-- | The server's default read buffer size.
recvBufferSize :: Int
recvBufferSize = 8192

consumers :: [(String, Socket.ClientSocket -> IO Int)]
consumers =
    [ ("plain Socket.recv     ", plainRecv)
    , ("iteratee stream", streamingConsumer)
    ]

main :: IO ()
main = do
    IO.hSetBuffering IO.stdout IO.LineBuffering
    opened <- Socket.listenTcp Socket.HostAny listenPort 1
    case opened of
        Left err -> error ("listenTcp failed: " ++ show err)
        Right socket -> do
            putStrLn "iteratee receiver: listening on 8090"
            putStrLn "consumer        | MB/s"
            mapM_ (measure socket) consumers
            _ <- Socket.closeListenSocket socket
            return ()

measure :: Socket.ListenSocket -> (String, Socket.ClientSocket -> IO Int) -> IO ()
measure socket (label, consume) = do
    accepted <- Socket.accept socket
    case accepted of
        Left err -> error ("accept failed: " ++ show err)
        Right (client, _) -> do
            start <- Clock.getCurrentTime
            processed <- consume client
            end <- Clock.getCurrentTime
            let seconds = realToFrac (Clock.diffUTCTime end start) :: Double
            putStrLn (label ++ " | " ++ showRounded (fromIntegral processed / 1000000 / seconds))
            _ <- Socket.closeClientSocket client
            return ()

-- | The raw Socket.recv loop, no iteratee: the reference throughput.
plainRecv :: Socket.ClientSocket -> IO Int
plainRecv client = go 0
  where
    go total = do
        received <- Socket.recv client recvBufferSize
        case received of
            Left err -> error ("recv failed: " ++ show err)
            Right bytes
                | BS.null bytes -> return total
                | otherwise -> go (total + BS.length bytes)

{- | Stream.socketEnumerator into a counting sink: pure iteratee streaming overhead,
no body retained.
-}
streamingConsumer :: Socket.ClientSocket -> IO Int
streamingConsumer client = do
    final <- Stream.socketEnumerator client recvBufferSize 0 countingSink
    result <- Iteratee.run final
    case result of
        Left err -> error ("stream failed: " ++ show err)
        Right total -> return total

-- | Sums chunk lengths to end of stream without retaining bytes.
countingSink :: Iteratee.Iter Stream.StreamError Int
countingSink = go 0
  where
    go n = Iteratee.NeedInput (consume n)
    consume n s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go n
            | otherwise -> go (n + BS.length bytes)
        Iteratee.EndOfStream _ -> Iteratee.Done n (Iteratee.EndOfStream Nothing)

showRounded :: Double -> String
showRounded x = show (fromIntegral (round (x * 10) :: Int) / 10 :: Double)
