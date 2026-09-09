{- | The receive side of the socket saturation bench (the subject under test).
It listens on a fixed port, accepts one connection, and drains the stream to
end of stream through the production MicroHttp.Network.Socket recv loop,
reporting throughput. A blocking GHC sender (bench/sender) keeps the pipe
full, so this measures the recv ceiling rather than the single-threaded
poll-bound ping-pong of bench/SocketBench.hs. Run via
scripts/socket-saturated-bench.sh or `make bench-socket-saturated`.
-}
module Main (main) where

import qualified Data.ByteString as BS
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import MicroHttp.Network.Socket

listenPort :: Port
listenPort = Port 8090

-- | The server's default read buffer size.
recvBufferSize :: Int
recvBufferSize = 8192

main :: IO ()
main = do
    opened <- listenTcp HostAny listenPort 1
    case opened of
        Left err -> error ("listenTcp failed: " ++ show err)
        Right socket -> do
            putStrLn "receiver: listening on 8090"
            accepted <- accept socket
            case accepted of
                Left err -> error ("accept failed: " ++ show err)
                Right client -> do
                    start <- getCurrentTime
                    total <- drain client 0
                    end <- getCurrentTime
                    report total (realToFrac (diffUTCTime end start))
                    _ <- closeClientSocket client
                    _ <- closeListenSocket socket
                    return ()

-- | Reads to end of stream, returning the byte count.
drain :: ClientSocket -> Int -> IO Int
drain client total = do
    received <- recv client recvBufferSize
    case received of
        Left err -> error ("recv failed: " ++ show err)
        Right bytes
            | BS.null bytes -> return total
            | otherwise -> drain client (total + BS.length bytes)

report :: Int -> Double -> IO ()
report total seconds = do
    let mbps = fromIntegral total / 1000000 / seconds
    putStrLn
        ( "receiver: "
            ++ show total
            ++ " bytes in "
            ++ showRounded seconds
            ++ " s = "
            ++ showRounded mbps
            ++ " MB/s"
        )

showRounded :: Double -> String
showRounded x = show (fromIntegral (round (x * 10) :: Int) / 10 :: Double)
