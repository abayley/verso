module MicroHttp.ServerLoggingSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import MicroHttp.Http (Method (..), RequestHead (..), Status (..))
import MicroHttp.Log (AccessEvent (..), Logger)
import MicroHttp.Network.Socket
import MicroHttp.Server
import qualified MicroHttp.TestApp as TestApp
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Server access logging" $ do
        it "given a normal request, when handled with a logger, then a received line and a completed line are recorded" $
            withConnectedPair $ \client served -> do
                events <- newIORef []
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- handleClient (loggingSettings events) (TestApp.appWithDocumentRoot documentRoot) served
                _ <- recv client 4096
                result `shouldBe` Right ()
                recorded <- captured events
                case recorded of
                    [RequestReceived received, RequestCompleted (Just completed) status bytesWritten durationMillis] -> do
                        requestMethod received `shouldBe` GET
                        requestPath received `shouldBe` []
                        requestMethod completed `shouldBe` GET
                        statusCode status `shouldBe` 200
                        (bytesWritten > 0) `shouldBe` True
                        (durationMillis >= 0) `shouldBe` True
                    _ -> expect ("unexpected log events: " ++ describe' recorded) False
        it "given a peer that stalls before completing the head, when handled with a short idle timeout, then a completed 408 line is still recorded" $
            withConnectedPair $ \client served -> do
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n")
                sent `shouldBe` Right ()
                events <- newIORef []
                result <- handleClient (shortIdleLoggingSettings events) (TestApp.appWithDocumentRoot documentRoot) served
                _ <- recv client 4096
                result `shouldBe` Right ()
                recorded <- captured events
                case recorded of
                    [RequestCompleted Nothing status _ _] ->
                        statusCode status `shouldBe` 408
                    _ -> expect ("expected a single completed 408 line, got: " ++ describe' recorded) False

loggingSettings :: IORef [AccessEvent] -> Settings
loggingSettings events =
    defaultSettings{settingsLogger = captureLogger events}

shortIdleLoggingSettings :: IORef [AccessEvent] -> Settings
shortIdleLoggingSettings events =
    defaultSettings{settingsLogger = captureLogger events, settingsIdleReadTimeoutMicros = 100000}

captureLogger :: IORef [AccessEvent] -> Logger
captureLogger events event = modifyIORef' events (event :)

captured :: IORef [AccessEvent] -> IO [AccessEvent]
captured events = reverse <$> readIORef events

-- | A coarse description of captured events for a failure message.
describe' :: [AccessEvent] -> String
describe' = show . map tagOf

tagOf :: AccessEvent -> String
tagOf event =
    case event of
        RequestReceived _ -> "received"
        RequestCompleted _ status _ _ -> "completed:" ++ show (statusCode status)
        RequestAborted _ reason _ -> "aborted:" ++ reason

documentRoot :: FilePath
documentRoot = "build"

loopback :: Host
loopback = HostIPv4 127 0 0 1

withConnectedPair :: (ClientSocket -> ClientSocket -> IO ()) -> IO ()
withConnectedPair use = do
    opened <- listenTcp HostAny (Port 0) 1
    case opened of
        Left err -> expect ("listenTcp failed: " ++ show err) False
        Right socket -> do
            queried <- boundPort socket
            case queried of
                Left err -> expect ("boundPort failed: " ++ show err) False
                Right port -> do
                    connected <- connectTcp loopback port
                    case connected of
                        Left err -> expect ("connectTcp failed: " ++ show err) False
                        Right client -> do
                            accepted <- accept socket
                            case accepted of
                                Left err -> do
                                    _ <- closeClientSocket client
                                    expect ("accept failed: " ++ show err) False
                                Right served -> do
                                    use client served
                                    _ <- closeClientSocket client
                                    return ()
            closed <- closeListenSocket socket
            closed `shouldBe` Right ()
