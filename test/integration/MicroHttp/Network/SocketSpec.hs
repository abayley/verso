module MicroHttp.Network.SocketSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Network.Socket
import Test.Hspec

-- Concurrent sender and receiver threads polling the same connection hang
-- intermittently under the MicroHs runtime; see spike/MicroHttp/Spike10.hs
-- for the retained reproducer. This suite transfers in single-threaded
-- rounds so each round fits the kernel socket buffers.
largePayloadChunkBytes :: Int
largePayloadChunkBytes = 65536

largePayloadChunkCount :: Int
largePayloadChunkCount = 8

largePayloadBytes :: Int
largePayloadBytes = largePayloadChunkBytes * largePayloadChunkCount

spec :: Spec
spec =
    describe "MicroHttp.Network.Socket" $ do
        it "given port zero, when listening and closing, then both operations succeed" $ do
            opened <- listenTcp HostAny (Port 0) 1
            case opened of
                Left err ->
                    expect ("listenTcp failed: " ++ show err) False
                Right socket -> do
                    closed <- closeListenSocket socket
                    closed `shouldBe` Right ()
        it "given a listening socket on port zero, when querying the bound port, then a non-zero port is returned" $
            withListeningSocket $ \socket -> do
                queried <- boundPort socket
                case queried of
                    Left err -> expect ("boundPort failed: " ++ show err) False
                    Right (Port port) -> expect ("expected non-zero port, got " ++ show port) (port > 0)
        it "given a listening socket, when a client connects to the bound port, then accept returns a client socket" $
            withListeningSocket $ \socket -> do
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
                                        closedServed <- closeClientSocket served
                                        closedClient <- closeClientSocket client
                                        closedServed `shouldBe` Right ()
                                        closedClient `shouldBe` Right ()
        it "given a payload larger than one read buffer, when sent in rounds, then the receiver reads every byte" $
            withConnectedPair $ \client served -> do
                let piece = BS.pack (replicate largePayloadChunkBytes 'x')
                total <- transferRounds client served (replicate largePayloadChunkCount piece)
                total `shouldBe` largePayloadBytes
        it "given a connected pair, when each side sends, then the other side receives the same bytes" $
            withConnectedPair $ \client served -> do
                sentToServer <- sendAll client (BS.pack "hello server")
                sentToServer `shouldBe` Right ()
                fromClient <- recv served 64
                fromClient `shouldBe` Right (BS.pack "hello server")
                sentToClient <- sendAll served (BS.pack "hello client")
                sentToClient `shouldBe` Right ()
                fromServer <- recv client 64
                fromServer `shouldBe` Right (BS.pack "hello client")
        it "given a peer that closed its socket, when receiving, then an empty result is returned" $
            withConnectedPair $ \client served -> do
                closed <- closeClientSocket client
                closed `shouldBe` Right ()
                received <- recv served 64
                received `shouldBe` Right BS.empty
        it "given a closed socket, when receiving or sending, then a socket error is returned" $
            withConnectedPair $ \_ served -> do
                closed <- closeClientSocket served
                closed `shouldBe` Right ()
                received <- recv served 16
                case received of
                    Left (SocketError operation _) -> operation `shouldBe` "recv"
                    Right bytes -> expect ("expected recv failure, got " ++ show bytes) False
                sent <- sendAll served (BS.pack "x")
                case sent of
                    Left (SocketError operation _) -> operation `shouldBe` "send"
                    Right () -> expect "expected send failure" False
        it "given a free port with no listener, when connecting, then a socket error is returned" $ do
            opened <- listenTcp HostAny (Port 0) 1
            case opened of
                Left err -> expect ("listenTcp failed: " ++ show err) False
                Right socket -> do
                    queried <- boundPort socket
                    closed <- closeListenSocket socket
                    closed `shouldBe` Right ()
                    case queried of
                        Left err -> expect ("boundPort failed: " ++ show err) False
                        Right port -> do
                            connected <- connectTcp loopback port
                            case connected of
                                Left (SocketError operation _) -> operation `shouldBe` "connect"
                                Right client -> do
                                    _ <- closeClientSocket client
                                    expect "expected connect failure" False

loopback :: Host
loopback = HostIPv4 127 0 0 1

transferRounds :: ClientSocket -> ClientSocket -> [BS.ByteString] -> IO Int
transferRounds _ _ [] = return 0
transferRounds sender receiver (piece : rest) = do
    sent <- sendAll sender piece
    sent `shouldBe` Right ()
    received <- drainExactly receiver (BS.length piece)
    remaining <- transferRounds sender receiver rest
    return (received + remaining)

drainExactly :: ClientSocket -> Int -> IO Int
drainExactly socket remaining
    | remaining <= 0 = return 0
    | otherwise = do
        received <- recv socket remaining
        case received of
            Left err -> do
                expect ("recv failed: " ++ show err) False
                return 0
            Right bytes
                | BS.null bytes -> return 0
                | otherwise -> do
                    more <- drainExactly socket (remaining - BS.length bytes)
                    return (BS.length bytes + more)

withConnectedPair :: (ClientSocket -> ClientSocket -> IO ()) -> IO ()
withConnectedPair use =
    withListeningSocket $ \socket -> do
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
                                _ <- closeClientSocket served
                                _ <- closeClientSocket client
                                return ()

withListeningSocket :: (ListenSocket -> IO ()) -> IO ()
withListeningSocket use = do
    opened <- listenTcp HostAny (Port 0) 1
    case opened of
        Left err -> expect ("listenTcp failed: " ++ show err) False
        Right socket -> do
            use socket
            closed <- closeListenSocket socket
            closed `shouldBe` Right ()
