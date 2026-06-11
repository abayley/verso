module MicroHttp.ServerSocketSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Network.Socket
import MicroHttp.Server
import qualified MicroHttp.TestApp as TestApp
import System.Directory (doesFileExist, removeFile)
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

smallBufferSettings :: Settings
smallBufferSettings =
    defaultSettings{settingsReadBufferBytes = 1024}

smallBodySettings :: Settings
smallBodySettings =
    defaultSettings{settingsReadBufferBytes = 1024, settingsMaxBodyBytes = 1024}

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
