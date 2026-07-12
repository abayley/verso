module MicroHttp.ServerLoggingSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified Data.List as List
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Middleware as Middleware
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import qualified System.Directory as Directory
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Server access logging" $ do
        it "given a normal request, when handled through the logging middleware, then a received line and a completed line are recorded" $
            withConnectedPair $ \client served conn -> do
                events <- IORef.newIORef []
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- Server.handleClient Server.defaultSettings (logged events documentApp) served conn
                _ <- Socket.recv client 4096
                result `shouldBe` Right ()
                recorded <- captured events
                case recorded of
                    [Log.RequestReceived _ received, Log.RequestCompleted _ (Just completed) status reqBytes respBytes durationMillis] -> do
                        Log.requestLineMethod received `shouldBe` "GET"
                        Log.requestLineTarget received `shouldBe` "/"
                        Log.requestLineMethod completed `shouldBe` "GET"
                        Http.statusCode status `shouldBe` 200
                        (reqBytes > 0) `shouldBe` True
                        (respBytes > 0) `shouldBe` True
                        (durationMillis >= 0) `shouldBe` True
                    _ -> expect ("unexpected log events: " ++ describe' recorded) False
        it "given a peer that stalls after the first line, when handled with a short idle timeout, then a completed 408 line is recorded" $
            withConnectedPair $ \client served conn -> do
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n")
                sent `shouldBe` Right ()
                events <- IORef.newIORef []
                result <- Server.handleClient shortIdleSettings (logged events (Middleware.withErrorResponses documentApp)) served conn
                _ <- Socket.recv client 4096
                result `shouldBe` Right ()
                recorded <- captured events
                case recorded of
                    [Log.RequestReceived _ _, Log.RequestCompleted _ _ status _ _ _] ->
                        Http.statusCode status `shouldBe` 408
                    _ -> expect ("expected received then completed 408, got: " ++ describe' recorded) False
        it "given a file logger, when a request is handled, then the access log file holds the request lines" $
            withConnectedPair $ \client served conn -> do
                removeIfExists accessLogPath
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- Server.handleClient Server.defaultSettings (Middleware.logRequests (Log.fileLogfmtLogger accessLogPath) documentApp) served conn
                _ <- Socket.recv client 4096
                result `shouldBe` Right ()
                contents <- readFile accessLogPath
                removeIfExists accessLogPath
                ("event=RQST" `List.isInfixOf` contents) `shouldBe` True
                ("event=RESP" `List.isInfixOf` contents) `shouldBe` True
                ("status=200" `List.isInfixOf` contents) `shouldBe` True

-- | A minimal framework-only fixture application (no Verso dependency): a @GET /@ probe.
documentApp :: Middleware.Application
documentApp =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        [Router.get "/" (\_ _ -> pure (Http.Response Http.okStatus [] (Http.StrictBody (BS.pack "ok\n"))))]

-- | Wraps an application with a capturing logging middleware (outermost).
logged :: IORef.IORef [Log.AccessEvent] -> Middleware.Application -> Middleware.Application
logged events = Middleware.logRequests (captureLogger events)

shortIdleSettings :: Server.Settings
shortIdleSettings = Server.defaultSettings{Server.settingsIdleReadTimeoutMicros = 100000}

accessLogPath :: FilePath
accessLogPath = "build/test-access.log"

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    present <- Directory.doesFileExist path
    Monad.when present (Directory.removeFile path)

captureLogger :: IORef.IORef [Log.AccessEvent] -> Log.Logger
captureLogger events event = IORef.modifyIORef' events (event :)

captured :: IORef.IORef [Log.AccessEvent] -> IO [Log.AccessEvent]
captured events = reverse <$> IORef.readIORef events

-- | A coarse description of captured events for a failure message.
describe' :: [Log.AccessEvent] -> String
describe' = show . map tagOf

tagOf :: Log.AccessEvent -> String
tagOf event =
    case event of
        Log.RequestReceived _ _ -> "received"
        Log.RequestCompleted _ _ status _ _ _ -> "completed:" ++ show (Http.statusCode status)
        Log.RequestAborted _ _ reason _ _ -> "aborted:" ++ reason

loopback :: Socket.Host
loopback = Socket.HostIPv4 127 0 0 1

withConnectedPair :: (Socket.ClientSocket -> Socket.ClientSocket -> Socket.ConnectionInfo -> IO ()) -> IO ()
withConnectedPair use = do
    opened <- Socket.listenTcp Socket.HostAny (Socket.Port 0) 1
    case opened of
        Left err -> expect ("listenTcp failed: " ++ show err) False
        Right socket -> do
            queried <- Socket.boundPort socket
            case queried of
                Left err -> expect ("boundPort failed: " ++ show err) False
                Right port -> do
                    connected <- Socket.connectTcp loopback port
                    case connected of
                        Left err -> expect ("connectTcp failed: " ++ show err) False
                        Right client -> do
                            accepted <- Socket.accept socket
                            case accepted of
                                Left err -> do
                                    _ <- Socket.closeClientSocket client
                                    expect ("accept failed: " ++ show err) False
                                Right (served, conn) -> do
                                    use client served conn
                                    _ <- Socket.closeClientSocket client
                                    return ()
            closed <- Socket.closeListenSocket socket
            closed `shouldBe` Right ()
