module MicroHttp.ServerSocketSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Middleware as Middleware
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import qualified System.Timeout as Timeout
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Server socket handling" $ do
        it "given a POST body larger than the read buffer, when handled over a socket, then the full body is saved" $
            withConnectedPair $ \client served conn -> do
                let body = replicate 5000 'x'
                    payload = "markdown=" ++ body
                    requestText =
                        "POST /documents/home HTTP/1.1\r\n"
                            ++ "Content-Length: "
                            ++ show (length payload)
                            ++ "\r\n\r\n"
                            ++ payload
                sent <- Socket.sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- Server.handleClient smallBufferSettings documentApp served conn
                saved <- FileSystem.readFileStrict documentFile
                Directory.removeFile documentFile
                result `shouldBe` Right ()
                length saved `shouldBe` 5000
        it "given a Content-Length above the body limit, when handled over a socket, then nothing is persisted" $
            withConnectedPair $ \client served conn -> do
                let payload = "markdown=" ++ replicate 5000 'x'
                    requestText =
                        "POST /documents/home HTTP/1.1\r\n"
                            ++ "Content-Length: "
                            ++ show (length payload)
                            ++ "\r\n\r\n"
                            ++ payload
                sent <- Socket.sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- Server.handleClient smallBodySettings smallBodyApp served conn
                persisted <- Directory.doesFileExist documentFile
                result `shouldBe` Right ()
                persisted `shouldBe` False
        it "given a handler that responds without consuming its body, when handled over a socket, then the connection closes cleanly" $
            withConnectedPair $ \client served conn -> do
                let body = "hello world!"
                    requestText =
                        "GET / HTTP/1.1\r\n"
                            ++ "Content-Length: "
                            ++ show (length body)
                            ++ "\r\n\r\n"
                            ++ body
                sent <- Socket.sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- Server.handleClient smallBufferSettings documentApp served conn
                received <- Socket.recv client 4096
                result `shouldBe` Right ()
                fmap (List.isInfixOf "200 OK" . BS.unpack) received `shouldBe` Right True
        it "given a handler that throws, when handled over a socket, then the crash is reported as a server error and the connection is closed" $
            withConnectedPair $ \client served conn -> do
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- Server.handleClient smallBufferSettings crashingApp served conn
                let crashed = case result of
                        Left (Server.ServerHandlerCrashed _) -> True
                        _ -> False
                crashed `shouldBe` True
                -- the peer sees the connection closed, not a hang: an empty read or a reset
                received <- Socket.recv client 4096
                either (const True) BS.null received `shouldBe` True
        it "given a peer that sends a partial request and stalls, when handled with a short idle timeout, then a 408 is returned" $
            withConnectedPair $ \client served conn -> do
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n")
                sent `shouldBe` Right ()
                result <- Server.handleClient shortIdleSettings documentApp served conn
                received <- Socket.recv client 4096
                result `shouldBe` Right ()
                fmap (List.isInfixOf "408 Request Timeout" . BS.unpack) received `shouldBe` Right True
        it "given a reader that stops draining a large response, when handled with a short idle write timeout, then the write fails within the bound instead of hanging" $
            withConnectedPair $ \client served conn -> do
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                -- The client never reads, so the kernel send buffers fill and
                -- the response write blocks; the short write timeout must
                -- bound it. The outer guard turns a regression into a failure
                -- rather than a hung suite.
                result <- Timeout.timeout testGuardMicros (Server.handleClient shortWriteSettings largeResponseApp served conn)
                _ <- Socket.recv client 4096
                case result of
                    Nothing -> expect "handleClient hung past the write timeout" False
                    Just (Left (Server.ServerWriteFailed (Stream.StreamWriteError err)))
                        | Socket.isTimeoutError err -> return ()
                    Just other -> expect ("expected a write timeout, got " ++ show other) False
        it "given a file body response, when handled over a socket, then the client receives a head with an exact Content-Length and the file bytes" $
            withConnectedPair $ \client served conn -> do
                BS.writeFile fileBodyFile (BS.pack "zero-copy!")
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- Server.handleClient Server.defaultSettings (fileBodyApp fileBodyFile 10) served conn
                received <- recvAll client
                Directory.removeFile fileBodyFile
                result `shouldBe` Right ()
                BS.unpack received
                    `shouldBe` "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nzero-copy!"
        it "given a sized streaming body, when handled over a socket, then the client receives a head with an exact Content-Length and the streamed bytes" $
            withConnectedPair $ \client served conn -> do
                BS.writeFile fileBodyFile (BS.pack "streamed-body!")
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- Server.handleClient Server.defaultSettings (sizedStreamApp fileBodyFile 14) served conn
                received <- recvAll client
                Directory.removeFile fileBodyFile
                result `shouldBe` Right ()
                BS.unpack received
                    `shouldBe` "HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\nstreamed-body!"
        it "given a reader that stops draining a large file body, when handled with a short idle write timeout, then the sendfile write fails within the bound instead of hanging" $
            withConnectedPair $ \client served conn -> do
                BS.writeFile largeFileBodyFile (BS.replicate largeFileBodyBytes 'x')
                sent <- Socket.sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                -- The client never reads, so the kernel send buffers fill and
                -- the sendfile body write parks on write readiness; the short
                -- write timeout must bound it (RFC-0014, via sendFileWithin).
                result <- Timeout.timeout testGuardMicros (Server.handleClient shortWriteSettings (fileBodyApp largeFileBodyFile largeFileBodyBytes) served conn)
                _ <- Socket.recv client 4096
                Directory.removeFile largeFileBodyFile
                case result of
                    Nothing -> expect "handleClient hung past the write timeout" False
                    Just (Left (Server.ServerWriteFailed (Stream.StreamWriteError err)))
                        | Socket.isTimeoutError err -> return ()
                    Just other -> expect ("expected a write timeout, got " ++ show other) False

-- | An application that serves a file body for a fixed path and size.
fileBodyApp :: FilePath -> Int -> Middleware.Application
fileBodyApp path size _ = pure (Http.Response Http.okStatus [] (Http.FileBody path size))

-- | An application that serves a file's bytes as a sized streaming body (RFC-0040).
sizedStreamApp :: FilePath -> Int -> Middleware.Application
sizedStreamApp path size _ = pure (Http.Response Http.okStatus [] (Http.SizedStreamBody size (Stream.fileEnumerator path)))

fileBodyFile :: FilePath
fileBodyFile = "server-filebody-test.tmp"

largeFileBodyFile :: FilePath
largeFileBodyFile = "server-filebody-large-test.tmp"

{- | A file body larger than the kernel send buffers, so a client that stops
reading forces the sendfile body write to block. 64 MiB, matching
'largeResponseApp', is comfortably above macOS loopback buffer autotuning.
-}
largeFileBodyBytes :: Int
largeFileBodyBytes = 64 * 1024 * 1024

-- | Reads from a socket until the peer closes (an empty read), concatenating.
recvAll :: Socket.ClientSocket -> IO BS.ByteString
recvAll socket = go []
  where
    go acc = do
        received <- Socket.recv socket 4096
        case received of
            Right bytes | not (BS.null bytes) -> go (bytes : acc)
            _ -> return (BS.concat (reverse acc))

smallBufferSettings :: Server.Settings
smallBufferSettings =
    Server.defaultSettings{Server.settingsReadBufferBytes = 1024}

-- | A short idle-read timeout so a stalled peer is bounded quickly in tests.
shortIdleSettings :: Server.Settings
shortIdleSettings =
    Server.defaultSettings{Server.settingsReadBufferBytes = 1024, Server.settingsIdleReadTimeoutMicros = 100000}

smallBodySettings :: Server.Settings
smallBodySettings =
    Server.defaultSettings{Server.settingsReadBufferBytes = 1024, Server.settingsMaxBodyBytes = 1024}

-- | A short idle-write timeout so a stalled reader is bounded quickly in tests.
shortWriteSettings :: Server.Settings
shortWriteSettings =
    Server.defaultSettings{Server.settingsIdleWriteTimeoutMicros = 100000}

{- | An application that returns a response far larger than the kernel send
buffers, so a client that stops reading forces the write to block. The body is
64 MiB: macOS loopback socket buffers autotune to several MiB, so a smaller
body can be fully absorbed before the write ever blocks, making the timeout
test flaky. 64 MiB is comfortably above any such buffer.
-}
largeResponseApp :: Middleware.Application
largeResponseApp _ =
    pure (Http.Response Http.okStatus [] (Http.StrictBody (BS.replicate (64 * 1024 * 1024) 'x')))

{- | An outer bound on the stalled-write test: well above the 100 ms write
timeout, so a hang (a regression) fails the test rather than wedging the suite.
-}
testGuardMicros :: Int
testGuardMicros = 5000000

{- | A minimal framework-only fixture application (no Verso dependency): a
@GET /@ probe and a @POST /documents/home@ save that persists the posted
form value, wrapped with the 400/408 error-response middleware.
-}
documentApp :: Middleware.Application
documentApp =
    Middleware.withErrorResponses (Router.serveRoutes (Server.parseLimits Server.defaultSettings) fixtureRoutes)

{- | The fixture application composed with a small body limit, since the body
bound now lives in the application stack (serveRoutes), not the server.
-}
smallBodyApp :: Middleware.Application
smallBodyApp =
    Middleware.withErrorResponses (Router.serveRoutes (Server.parseLimits smallBodySettings) fixtureRoutes)

-- | The fixture routes: an OK probe and a body-persisting save.
fixtureRoutes :: [Router.Route]
fixtureRoutes =
    [ Router.get "/" (\_ _ -> pure okResponse)
    , Router.post "/documents/home" saveHandler
    ]

-- | Persists the posted body's @markdown=@ value to 'documentFile'.
saveHandler :: Router.Handler
saveHandler _ _ = do
    bytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) 1048576
    Iteratee.liftIO (BS.writeFile documentFile (BS.drop (length "markdown=") bytes))
    pure okResponse

-- | An application whose handler throws mid-request, as a bug in a handler would.
crashingApp :: Http.Application
crashingApp _ = Iteratee.liftIO (ioError (userError "handler bug"))

-- | A minimal @200@ response for the fixture routes.
okResponse :: Http.Response
okResponse = Http.Response Http.okStatus [] (Http.StrictBody (BS.pack "ok\n"))

documentFile :: FilePath
documentFile = "build/home.md"

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
