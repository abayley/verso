module MicroHttp.ServerSocketSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf)
import MicroHttp.Http (Response (..), ResponseBody (..), okStatus)
import MicroHttp.Middleware (Application, withErrorResponses)
import MicroHttp.Network.Socket
import MicroHttp.Router (serveRoutes)
import MicroHttp.Server
import MicroHttp.Stream (StreamError (..))
import System.Directory (doesFileExist, removeFile)
import System.Timeout (timeout)
import Test.Hspec
import qualified Verso.App as App

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
                sent <- sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- handleClient smallBufferSettings documentApp served conn
                saved <- readFile documentFile
                removeFile documentFile
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
                sent <- sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- handleClient smallBodySettings smallBodyApp served conn
                persisted <- doesFileExist documentFile
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
                sent <- sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- handleClient smallBufferSettings documentApp served conn
                received <- recv client 4096
                result `shouldBe` Right ()
                fmap (isInfixOf "200 OK" . BS.unpack) received `shouldBe` Right True
        it "given a peer that sends a partial request and stalls, when handled with a short idle timeout, then a 408 is returned" $
            withConnectedPair $ \client served conn -> do
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n")
                sent `shouldBe` Right ()
                result <- handleClient shortIdleSettings documentApp served conn
                received <- recv client 4096
                result `shouldBe` Right ()
                fmap (isInfixOf "408 Request Timeout" . BS.unpack) received `shouldBe` Right True
        it "given a reader that stops draining a large response, when handled with a short idle write timeout, then the write fails within the bound instead of hanging" $
            withConnectedPair $ \client served conn -> do
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                -- The client never reads, so the kernel send buffers fill and
                -- the response write blocks; the short write timeout must
                -- bound it. The outer guard turns a regression into a failure
                -- rather than a hung suite.
                result <- timeout testGuardMicros (handleClient shortWriteSettings largeResponseApp served conn)
                _ <- recv client 4096
                case result of
                    Nothing -> expect "handleClient hung past the write timeout" False
                    Just (Left (ServerWriteFailed (StreamWriteError err)))
                        | isTimeoutError err -> return ()
                    Just other -> expect ("expected a write timeout, got " ++ show other) False
        it "given a file body response, when handled over a socket, then the client receives a head with an exact Content-Length and the file bytes" $
            withConnectedPair $ \client served conn -> do
                BS.writeFile fileBodyFile (BS.pack "zero-copy!")
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                result <- handleClient defaultSettings (fileBodyApp fileBodyFile 10) served conn
                received <- recvAll client
                removeFile fileBodyFile
                result `shouldBe` Right ()
                BS.unpack received
                    `shouldBe` "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nzero-copy!"
        it "given a reader that stops draining a large file body, when handled with a short idle write timeout, then the sendfile write fails within the bound instead of hanging" $
            withConnectedPair $ \client served conn -> do
                BS.writeFile largeFileBodyFile (BS.replicate largeFileBodyBytes 'x')
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                -- The client never reads, so the kernel send buffers fill and
                -- the sendfile body write parks on write readiness; the short
                -- write timeout must bound it (RFC-0014, via sendFileWithin).
                result <- timeout testGuardMicros (handleClient shortWriteSettings (fileBodyApp largeFileBodyFile largeFileBodyBytes) served conn)
                _ <- recv client 4096
                removeFile largeFileBodyFile
                case result of
                    Nothing -> expect "handleClient hung past the write timeout" False
                    Just (Left (ServerWriteFailed (StreamWriteError err)))
                        | isTimeoutError err -> return ()
                    Just other -> expect ("expected a write timeout, got " ++ show other) False

-- | An application that serves a file body for a fixed path and size.
fileBodyApp :: FilePath -> Int -> Application
fileBodyApp path size _ = pure (Response okStatus [] (FileBody path size))

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
recvAll :: ClientSocket -> IO BS.ByteString
recvAll socket = go []
  where
    go acc = do
        received <- recv socket 4096
        case received of
            Right bytes | not (BS.null bytes) -> go (bytes : acc)
            _ -> return (BS.concat (reverse acc))

smallBufferSettings :: Settings
smallBufferSettings =
    defaultSettings{settingsReadBufferBytes = 1024}

-- | A short idle-read timeout so a stalled peer is bounded quickly in tests.
shortIdleSettings :: Settings
shortIdleSettings =
    defaultSettings{settingsReadBufferBytes = 1024, settingsIdleReadTimeoutMicros = 100000}

smallBodySettings :: Settings
smallBodySettings =
    defaultSettings{settingsReadBufferBytes = 1024, settingsMaxBodyBytes = 1024}

-- | A short idle-write timeout so a stalled reader is bounded quickly in tests.
shortWriteSettings :: Settings
shortWriteSettings =
    defaultSettings{settingsIdleWriteTimeoutMicros = 100000}

{- | An application that returns a response far larger than the kernel send
buffers, so a client that stops reading forces the write to block. The body is
64 MiB: macOS loopback socket buffers autotune to several MiB, so a smaller
body can be fully absorbed before the write ever blocks, making the timeout
test flaky. 64 MiB is comfortably above any such buffer.
-}
largeResponseApp :: Application
largeResponseApp _ =
    pure (Response okStatus [] (StrictBody (BS.replicate (64 * 1024 * 1024) 'x')))

{- | An outer bound on the stalled-write test: well above the 100 ms write
timeout, so a hang (a regression) fails the test rather than wedging the suite.
-}
testGuardMicros :: Int
testGuardMicros = 5000000

-- | The document application wrapped with the 400/408 error-response middleware.
documentApp :: Application
documentApp =
    withErrorResponses (App.appWithDocumentRoot documentRoot)

{- | The document application composed with a small body limit, since the body
bound now lives in the application stack (serveRoutes), not the server.
-}
smallBodyApp :: Application
smallBodyApp =
    withErrorResponses (serveRoutes (parseLimits smallBodySettings) (App.documentRoutes "paper" documentRoot))

documentRoot :: FilePath
documentRoot = "build"

documentFile :: FilePath
documentFile = documentRoot ++ "/home.md"

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
