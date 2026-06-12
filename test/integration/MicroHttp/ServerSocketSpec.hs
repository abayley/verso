module MicroHttp.ServerSocketSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf)
import MicroHttp.Http (Response (..), ResponseBody (..), okStatus)
import MicroHttp.Network.Socket
import MicroHttp.Server
import MicroHttp.Stream (StreamError (..))
import qualified MicroHttp.TestApp as TestApp
import System.Directory (doesFileExist, removeFile)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Server socket handling" $ do
        it "given a POST body larger than the read buffer, when handled over a socket, then the full body is saved" $
            withConnectedPair $ \client served -> do
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
                result <- handleClient smallBufferSettings (TestApp.appWithDocumentRoot documentRoot) served
                saved <- readFile documentFile
                removeFile documentFile
                result `shouldBe` Right ()
                length saved `shouldBe` 5000
        it "given a Content-Length above the body limit, when handled over a socket, then nothing is persisted" $
            withConnectedPair $ \client served -> do
                let payload = "markdown=" ++ replicate 5000 'x'
                    requestText =
                        "POST /documents/home HTTP/1.1\r\n"
                            ++ "Content-Length: "
                            ++ show (length payload)
                            ++ "\r\n\r\n"
                            ++ payload
                sent <- sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- handleClient smallBodySettings (TestApp.appWithDocumentRoot documentRoot) served
                persisted <- doesFileExist documentFile
                result `shouldBe` Right ()
                persisted `shouldBe` False
        it "given a handler that responds without consuming its body, when handled over a socket, then the connection closes cleanly" $
            withConnectedPair $ \client served -> do
                let body = "hello world!"
                    requestText =
                        "GET / HTTP/1.1\r\n"
                            ++ "Content-Length: "
                            ++ show (length body)
                            ++ "\r\n\r\n"
                            ++ body
                sent <- sendAll client (BS.pack requestText)
                sent `shouldBe` Right ()
                result <- handleClient smallBufferSettings (TestApp.appWithDocumentRoot documentRoot) served
                received <- recv client 4096
                result `shouldBe` Right ()
                fmap (isInfixOf "200 OK" . BS.unpack) received `shouldBe` Right True
        it "given a peer that sends a partial request and stalls, when handled with a short idle timeout, then a 408 is returned" $
            withConnectedPair $ \client served -> do
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n")
                sent `shouldBe` Right ()
                result <- handleClient shortIdleSettings (TestApp.appWithDocumentRoot documentRoot) served
                received <- recv client 4096
                result `shouldBe` Right ()
                fmap (isInfixOf "408 Request Timeout" . BS.unpack) received `shouldBe` Right True
        it "given a reader that stops draining a large response, when handled with a short idle write timeout, then the write fails within the bound instead of hanging" $
            withConnectedPair $ \client served -> do
                sent <- sendAll client (BS.pack "GET / HTTP/1.1\r\n\r\n")
                sent `shouldBe` Right ()
                -- The client never reads, so the kernel send buffers fill and
                -- the response write blocks; the short write timeout must
                -- bound it. The outer guard turns a regression into a failure
                -- rather than a hung suite.
                result <- timeout testGuardMicros (handleClient shortWriteSettings largeResponseApp served)
                _ <- recv client 4096
                case result of
                    Nothing -> expect "handleClient hung past the write timeout" False
                    Just (Left (ServerWriteFailed (StreamWriteError err)))
                        | isTimeoutError err -> return ()
                    Just other -> expect ("expected a write timeout, got " ++ show other) False

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

documentRoot :: FilePath
documentRoot = "build"

documentFile :: FilePath
documentFile = documentRoot ++ "/home.md"

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
