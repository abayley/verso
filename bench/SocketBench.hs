{- | A loopback throughput baseline for MicroHttp.Network.Socket, isolated
from the iteratee layer. It transfers a fixed volume through the real
recv/sendAll seam in single-threaded rounds (the regime the server runs
in, and the only one safe under the MicroHs concurrent-transfer
limitation) and reports MB/s per recv buffer size. This is a measurement
tool, not a pass/fail test; run it with `make bench-socket`.
-}
module Main (main) where

import qualified Data.ByteString.Char8 as BS
import Data.List (sort)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import MicroHttp.Network.Socket

{- | Bytes sent per round; small enough to fit the loopback send buffer so a
single-threaded send completes without a concurrent reader.
-}
batchBytes :: Int
batchBytes = 32768

-- | Rounds per timed repetition (repBytes = rounds * batchBytes).
repRounds :: Int
repRounds = 1600

-- | Timed repetitions per buffer size; their min and median are reported.
reps :: Int
reps = 5

-- | The recv buffer sizes to sweep, including the server's 8 KB default.
bufferSizes :: [Int]
bufferSizes = [4096, 8192, 16384, 32768]

main :: IO ()
main =
    withConnectedPair $ \client served -> do
        let batch = BS.replicate batchBytes 'x'
        putStrLn "MicroHttp.Network.Socket loopback throughput baseline"
        putStrLn ("batch " ++ show batchBytes ++ " B, " ++ show repRounds ++ " rounds/rep, " ++ show reps ++ " reps/size")
        putStrLn "recv buffer (B) | min MB/s | median MB/s"
        mapM_ (benchSize client served batch) bufferSizes

benchSize :: ClientSocket -> ClientSocket -> BS.ByteString -> Int -> IO ()
benchSize client served batch bufSize = do
    _warmup <- runRep client served batch bufSize
    rates <- mapM (const (runRep client served batch bufSize)) [1 .. reps]
    let sorted = sort rates
    putStrLn
        ( pad 15 (show bufSize)
            ++ " | "
            ++ pad 8 (showRate (head sorted))
            ++ " | "
            ++ showRate (sorted !! (reps `div` 2))
        )

-- | Runs one timed repetition and returns its throughput in MB/s.
runRep :: ClientSocket -> ClientSocket -> BS.ByteString -> Int -> IO Double
runRep client served batch bufSize = do
    start <- getCurrentTime
    rounds client served batch bufSize repRounds
    end <- getCurrentTime
    let seconds = realToFrac (diffUTCTime end start) :: Double
        moved = fromIntegral (repRounds * BS.length batch) :: Double
    return (moved / 1000000 / seconds)

rounds :: ClientSocket -> ClientSocket -> BS.ByteString -> Int -> Int -> IO ()
rounds _ _ _ _ 0 = return ()
rounds client served batch bufSize remaining = do
    sent <- sendAll client batch
    case sent of
        Left err -> error ("sendAll failed: " ++ show err)
        Right () -> drain served bufSize (BS.length batch)
    rounds client served batch bufSize (remaining - 1)

-- | Reads exactly @total@ bytes from the socket in @bufSize@ chunks.
drain :: ClientSocket -> Int -> Int -> IO ()
drain sock bufSize total
    | total <= 0 = return ()
    | otherwise = do
        received <- recv sock bufSize
        case received of
            Left err -> error ("recv failed: " ++ show err)
            Right bytes
                | BS.null bytes -> error "recv returned end of stream mid-transfer"
                | otherwise -> drain sock bufSize (total - BS.length bytes)

showRate :: Double -> String
showRate x =
    show (fromIntegral (round (x * 10) :: Int) / 10 :: Double)

pad :: Int -> String -> String
pad width text = text ++ replicate (max 0 (width - length text)) ' '

loopback :: Host
loopback = HostIPv4 127 0 0 1

withConnectedPair :: (ClientSocket -> ClientSocket -> IO ()) -> IO ()
withConnectedPair use = do
    opened <- listenTcp HostAny (Port 0) 1
    case opened of
        Left err -> error ("listenTcp failed: " ++ show err)
        Right socket -> do
            queried <- boundPort socket
            case queried of
                Left err -> error ("boundPort failed: " ++ show err)
                Right port -> do
                    connected <- connectTcp loopback port
                    case connected of
                        Left err -> error ("connectTcp failed: " ++ show err)
                        Right client -> do
                            accepted <- accept socket
                            case accepted of
                                Left err -> error ("accept failed: " ++ show err)
                                Right served -> do
                                    use client served
                                    _ <- closeClientSocket served
                                    _ <- closeClientSocket client
                                    return ()
            _ <- closeListenSocket socket
            return ()
