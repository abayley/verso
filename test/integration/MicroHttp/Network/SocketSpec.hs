module MicroHttp.Network.SocketSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Foreign.C.Error as Error
import qualified MicroHttp.Network.Socket as Socket
import qualified System.Directory as Directory
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
            opened <- Socket.listenTcp Socket.HostAny (Socket.Port 0) 1
            case opened of
                Left err ->
                    expect ("listenTcp failed: " ++ show err) False
                Right socket -> do
                    closed <- Socket.closeListenSocket socket
                    closed `shouldBe` Right ()
        it "given a listening socket on port zero, when querying the bound port, then a non-zero port is returned" $
            withListeningSocket $ \socket -> do
                queried <- Socket.boundPort socket
                case queried of
                    Left err -> expect ("boundPort failed: " ++ show err) False
                    Right (Socket.Port port) -> expect ("expected non-zero port, got " ++ show port) (port > 0)
        it "given a listening socket, when a client connects to the bound port, then accept returns a client socket" $
            withListeningSocket $ \socket -> do
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
                                    Right (served, _conn) -> do
                                        closedServed <- Socket.closeClientSocket served
                                        closedClient <- Socket.closeClientSocket client
                                        closedServed `shouldBe` Right ()
                                        closedClient `shouldBe` Right ()
        it "given a payload larger than one read buffer, when sent in rounds, then the receiver reads every byte" $
            withConnectedPair $ \client served -> do
                let piece = BS.pack (replicate largePayloadChunkBytes 'x')
                total <- transferRounds client served (replicate largePayloadChunkCount piece)
                total `shouldBe` largePayloadBytes
        it "given a connected pair, when each side sends, then the other side receives the same bytes" $
            withConnectedPair $ \client served -> do
                sentToServer <- Socket.sendAll client (BS.pack "hello server")
                sentToServer `shouldBe` Right ()
                fromClient <- Socket.recv served 64
                fromClient `shouldBe` Right (BS.pack "hello server")
                sentToClient <- Socket.sendAll served (BS.pack "hello client")
                sentToClient `shouldBe` Right ()
                fromServer <- Socket.recv client 64
                fromServer `shouldBe` Right (BS.pack "hello client")
        it "given a peer that closed its socket, when receiving, then an empty result is returned" $
            withConnectedPair $ \client served -> do
                closed <- Socket.closeClientSocket client
                closed `shouldBe` Right ()
                received <- Socket.recv served 64
                received `shouldBe` Right BS.empty
        it "given a closed socket, when receiving or sending, then a socket error is returned" $
            withConnectedPair $ \_ served -> do
                closed <- Socket.closeClientSocket served
                closed `shouldBe` Right ()
                received <- Socket.recv served 16
                case received of
                    Left (Socket.SocketError operation _) -> operation `shouldBe` "recv"
                    Right bytes -> expect ("expected recv failure, got " ++ show bytes) False
                sent <- Socket.sendAll served (BS.pack "x")
                case sent of
                    Left (Socket.SocketError operation _) -> operation `shouldBe` "send"
                    Right () -> expect "expected send failure" False
        it "given an existing file, when its size is queried, then the byte count is returned" $ do
            BS.writeFile sendFileTestFile (BS.pack "0123456789")
            size <- Socket.fileSizeBytes sendFileTestFile
            Directory.removeFile sendFileTestFile
            size `shouldBe` Just 10
        it "given a missing file, when its size is queried, then Nothing is returned" $ do
            size <- Socket.fileSizeBytes "no-such-sendfile-test-file.tmp"
            size `shouldBe` Nothing
        it "given a file, when sent over a connected pair via sendfile, then the receiver reads the file bytes" $
            withConnectedPair $ \client served -> do
                let payload = BS.pack "zero-copy file send"
                BS.writeFile sendFileTestFile payload
                opened <- Socket.openFileRead sendFileTestFile
                case opened of
                    Nothing -> expect "openFileRead failed" False
                    Just fd -> do
                        sent <- Socket.sendFileWithin 0 served fd 0 (BS.length payload)
                        Socket.closeFileFd fd
                        Directory.removeFile sendFileTestFile
                        sent `shouldBe` Right ()
                        received <- Socket.recv client 64
                        received `shouldBe` Right payload
        it "given a free port with no listener, when connecting, then a socket error is returned" $ do
            opened <- Socket.listenTcp Socket.HostAny (Socket.Port 0) 1
            case opened of
                Left err -> expect ("listenTcp failed: " ++ show err) False
                Right socket -> do
                    queried <- Socket.boundPort socket
                    closed <- Socket.closeListenSocket socket
                    closed `shouldBe` Right ()
                    case queried of
                        Left err -> expect ("boundPort failed: " ++ show err) False
                        Right port -> do
                            connected <- Socket.connectTcp loopback port
                            case connected of
                                Left (Socket.SocketError operation _) -> operation `shouldBe` "connect"
                                Right client -> do
                                    _ <- Socket.closeClientSocket client
                                    expect "expected connect failure" False
        it "given a port already bound on the same address, when listening again, then it fails with EADDRINUSE" $ do
            opened <- Socket.listenTcp loopback (Socket.Port 0) 1
            case opened of
                Left err -> expect ("listenTcp failed: " ++ show err) False
                Right socket -> do
                    queried <- Socket.boundPort socket
                    case queried of
                        Left err -> expect ("boundPort failed: " ++ show err) False
                        Right port -> do
                            again <- Socket.listenTcp loopback port 1
                            case again of
                                Right second -> do
                                    _ <- Socket.closeListenSocket second
                                    expect "expected the second bind to fail" False
                                Left (Socket.SocketError operation errno) -> do
                                    operation `shouldBe` "bind"
                                    -- Compared as a Bool: GHC's Errno has no Show instance.
                                    (errno == Error.eADDRINUSE) `shouldBe` True
                    closed <- Socket.closeListenSocket socket
                    closed `shouldBe` Right ()
        -- The probe exists because a clash is not always a bind failure: with SO_REUSEADDR
        -- a wildcard bind succeeds alongside a listener on 127.0.0.1, and then loopback
        -- traffic goes to the other process. Nothing in bind() reports that, so the only
        -- way to see it is to ask the port whether anyone answers.
        it "given a listener on the probed address, when probing, then it reports occupied" $ do
            opened <- Socket.listenTcp loopback (Socket.Port 0) 1
            case opened of
                Left err -> expect ("listenTcp failed: " ++ show err) False
                Right socket -> do
                    queried <- Socket.boundPort socket
                    case queried of
                        Left err -> expect ("boundPort failed: " ++ show err) False
                        Right port -> do
                            busy <- Socket.probeListener loopback port
                            busy `shouldBe` True
                    closed <- Socket.closeListenSocket socket
                    closed `shouldBe` Right ()
        it "given no listener on the probed address, when probing, then it reports free" $ do
            -- Bind to claim a port, read it, then release it: the kernel picked it, so
            -- nothing else is expected to be there once it is closed.
            opened <- Socket.listenTcp loopback (Socket.Port 0) 1
            case opened of
                Left err -> expect ("listenTcp failed: " ++ show err) False
                Right socket -> do
                    queried <- Socket.boundPort socket
                    closed <- Socket.closeListenSocket socket
                    closed `shouldBe` Right ()
                    case queried of
                        Left err -> expect ("boundPort failed: " ++ show err) False
                        Right port -> do
                            busy <- Socket.probeListener loopback port
                            busy `shouldBe` False

loopback :: Socket.Host
loopback = Socket.HostIPv4 127 0 0 1

sendFileTestFile :: FilePath
sendFileTestFile = "sendfile-socket-test.tmp"

transferRounds :: Socket.ClientSocket -> Socket.ClientSocket -> [BS.ByteString] -> IO Int
transferRounds _ _ [] = return 0
transferRounds sender receiver (piece : rest) = do
    sent <- Socket.sendAll sender piece
    sent `shouldBe` Right ()
    received <- drainExactly receiver (BS.length piece)
    remaining <- transferRounds sender receiver rest
    return (received + remaining)

drainExactly :: Socket.ClientSocket -> Int -> IO Int
drainExactly socket remaining
    | remaining <= 0 = return 0
    | otherwise = do
        received <- Socket.recv socket remaining
        case received of
            Left err -> do
                expect ("recv failed: " ++ show err) False
                return 0
            Right bytes
                | BS.null bytes -> return 0
                | otherwise -> do
                    more <- drainExactly socket (remaining - BS.length bytes)
                    return (BS.length bytes + more)

withConnectedPair :: (Socket.ClientSocket -> Socket.ClientSocket -> IO ()) -> IO ()
withConnectedPair use =
    withListeningSocket $ \socket -> do
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
                            Right (served, _conn) -> do
                                use client served
                                _ <- Socket.closeClientSocket served
                                _ <- Socket.closeClientSocket client
                                return ()

-- A second bind on the SAME address and port must fail, and must say why. The
-- errno is the whole message: EADDRINUSE means "one is already running", which is
-- a different instruction to the caller than a permission error.
withListeningSocket :: (Socket.ListenSocket -> IO ()) -> IO ()
withListeningSocket use = do
    opened <- Socket.listenTcp Socket.HostAny (Socket.Port 0) 1
    case opened of
        Left err -> expect ("listenTcp failed: " ++ show err) False
        Right socket -> do
            use socket
            closed <- Socket.closeListenSocket socket
            closed `shouldBe` Right ()
