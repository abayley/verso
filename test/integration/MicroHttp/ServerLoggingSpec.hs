module MicroHttp.ServerLoggingSpec (spec) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import MicroHttp.Http (Status (..))
import MicroHttp.Log (AccessEvent (..), Logger, RequestLine (..), fileLogfmtLogger)
import MicroHttp.Middleware (Application, logRequests, withErrorResponses)
import MicroHttp.Network.Socket
import MicroHttp.Server
import System.Directory (doesFileExist, removeFile)
import Test.Hspec
import qualified Verso.App as App

spec :: Spec
spec =
    describe "MicroHttp.Server access logging" $ do
        it "given a normal request, when handled through the logging middleware, then a received line and a completed line are recorded" $
            withConnectedPair $ \client served conn -> do
                events <- newIORef []
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- handleClient defaultSettings (logged events documentApp) served conn
                _ <- recv client 4096
                result `shouldBe` Right ()
                recorded <- captured events
                case recorded of
                    [RequestReceived _ received, RequestCompleted _ (Just completed) status reqBytes respBytes durationMillis] -> do
                        requestLineMethod received `shouldBe` "GET"
                        requestLineTarget received `shouldBe` "/"
                        requestLineMethod completed `shouldBe` "GET"
                        statusCode status `shouldBe` 200
                        (reqBytes > 0) `shouldBe` True
                        (respBytes > 0) `shouldBe` True
                        (durationMillis >= 0) `shouldBe` True
                    _ -> expect ("unexpected log events: " ++ describe' recorded) False
        it "given a peer that stalls after the first line, when handled with a short idle timeout, then a completed 408 line is recorded" $
            withConnectedPair $ \client served conn -> do
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n")
                sent `shouldBe` Right ()
                events <- newIORef []
                result <- handleClient shortIdleSettings (logged events (withErrorResponses documentApp)) served conn
                _ <- recv client 4096
                result `shouldBe` Right ()
                recorded <- captured events
                case recorded of
                    [RequestReceived _ _, RequestCompleted _ _ status _ _ _] ->
                        statusCode status `shouldBe` 408
                    _ -> expect ("expected received then completed 408, got: " ++ describe' recorded) False
        it "given a file logger, when a request is handled, then the access log file holds the request lines" $
            withConnectedPair $ \client served conn -> do
                removeIfExists accessLogPath
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- handleClient defaultSettings (logRequests (fileLogfmtLogger accessLogPath) documentApp) served conn
                _ <- recv client 4096
                result `shouldBe` Right ()
                contents <- readFile accessLogPath
                removeIfExists accessLogPath
                ("event=RQST" `isInfixOf` contents) `shouldBe` True
                ("event=RESP" `isInfixOf` contents) `shouldBe` True
                ("status=200" `isInfixOf` contents) `shouldBe` True

-- | The document application (frames and routes; no middleware).
documentApp :: Application
documentApp = App.appWithDocumentRoot documentRoot

-- | Wraps an application with a capturing logging middleware (outermost).
logged :: IORef [AccessEvent] -> Application -> Application
logged events = logRequests (captureLogger events)

shortIdleSettings :: Settings
shortIdleSettings = defaultSettings{settingsIdleReadTimeoutMicros = 100000}

accessLogPath :: FilePath
accessLogPath = "build/test-access.log"

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    present <- doesFileExist path
    when present (removeFile path)

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
        RequestReceived _ _ -> "received"
        RequestCompleted _ _ status _ _ _ -> "completed:" ++ show (statusCode status)
        RequestAborted _ _ reason _ _ -> "aborted:" ++ reason

documentRoot :: FilePath
documentRoot = "build"

loopback :: Host
loopback = HostIPv4 127 0 0 1

withConnectedPair :: (ClientSocket -> ClientSocket -> ConnectionInfo -> IO ()) -> IO ()
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
                                Right (served, conn) -> do
                                    use client served conn
                                    _ <- closeClientSocket client
                                    return ()
            closed <- closeListenSocket socket
            closed `shouldBe` Right ()
