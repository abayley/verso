module MicroHttp.ServerConcurrencySpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Monad (void)
import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Network.Socket
import MicroHttp.Router (get, serveRoutes)
import MicroHttp.Server (Application, defaultSettings, handleClient, parseLimits)
import Test.Hspec

-- | Enough connections to interleave, kept small so the example stays fast.
connectionCount :: Int
connectionCount = 6

{- | A response body large enough to force a lazily-built ByteString, the
path that the MicroHs forked-thread corruption bug used to empty. Each
connection uses a distinct fill byte so a crossed or corrupted response is
detectable.
-}
bodySize :: Int
bodySize = 200000

spec :: Spec
spec =
    describe "MicroHttp.Server concurrency" $
        it "given several connections handled concurrently, when each returns a large body, then every response is intact" $ do
            results <- runConcurrentHandlers connectionCount
            results `shouldBe` replicate connectionCount True

{- | Opens @count@ connections, hands each to a forked 'handleClient' while a
forked client drives it, and collects whether each response came back whole.
-}
runConcurrentHandlers :: Int -> IO [Bool]
runConcurrentHandlers count = do
    opened <- listenTcp HostAny (Port 0) 16
    case opened of
        Left err -> fail' ("listenTcp failed: " ++ show err)
        Right lsock -> do
            queried <- boundPort lsock
            case queried of
                Left err -> fail' ("boundPort failed: " ++ show err)
                Right port -> do
                    slots <- mapM (startPair lsock port) [0 .. count - 1]
                    results <- mapM takeMVar slots
                    _ <- closeListenSocket lsock
                    return results

-- | Connects and accepts one pair, then forks the handler and the client.
startPair :: ListenSocket -> Port -> Int -> IO (MVar Bool)
startPair lsock port index = do
    let tag = toEnum (fromEnum 'a' + index)
    connected <- connectTcp loopback port
    accepted <- accept lsock
    case (connected, accepted) of
        (Right client, Right (served, conn)) -> do
            slot <- newEmptyMVar
            _ <- forkIO (void (handleClient defaultSettings (taggedApp tag) served conn))
            _ <- forkIO (runClient client tag slot)
            return slot
        _ -> fail' "connect/accept failed"

{- | A routed application that responds with a large body filled with @tag@.
It frames the request first (like a real application), so the large lazily
built body is forced after the read, matching the production path.
-}
taggedApp :: Char -> Application
taggedApp tag =
    serveRoutes
        (parseLimits defaultSettings)
        [get "/" (\_ _ -> pure (Response okStatus [] (StrictBody (BS.pack (replicate bodySize tag)))))]

{- | Sends a minimal request, reads the whole response, and reports whether
the body is exactly @bodySize@ bytes of @tag@.
-}
runClient :: ClientSocket -> Char -> MVar Bool -> IO ()
runClient client tag slot = do
    _ <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
    response <- readAll client BS.empty
    let body = afterHeaders response
    putMVar slot (BS.length body == bodySize && BS.all (== tag) body)

-- | Reads to end of stream.
readAll :: ClientSocket -> BS.ByteString -> IO BS.ByteString
readAll client acc = do
    received <- recv client 16384
    case received of
        Left _ -> return acc
        Right bytes
            | BS.null bytes -> return acc
            | otherwise -> readAll client (BS.append acc bytes)

afterHeaders :: BS.ByteString -> BS.ByteString
afterHeaders response =
    case BS.breakSubstring (BS.pack "\r\n\r\n") response of
        (_, rest) -> BS.drop 4 rest

loopback :: Host
loopback = HostIPv4 127 0 0 1

fail' :: String -> IO a
fail' message = do
    expect message False
    error message
