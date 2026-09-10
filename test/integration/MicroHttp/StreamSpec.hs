module MicroHttp.StreamSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Stream producers" $ do
        it "given a socket enumerator and a bound, when a body is streamed through takeN to a collecting consumer, then the bounded bytes round-trip" $
            withConnectedPair $ \client served -> do
                let payload = replicate 5000 'x' ++ replicate 100 'y'
                sent <- Socket.sendAll client (BS.pack payload)
                sent `shouldBe` Right ()
                final <- Stream.socketEnumerator served 1024 0 (Iteratee.takeN 5000 (Iteratee.readBodyStrict bodyTooLarge 100000))
                result <- Iteratee.run final
                fmap BS.length result `shouldBe` Right 5000
        it "given a socket sink, when a strict body is streamed into it, then the peer receives the bytes" $
            withConnectedPair $ \client served -> do
                final <- Iteratee.strictEnumerator (BS.pack "hello sink") (Stream.socketSinkI client)
                result <- Iteratee.run final
                result `shouldBe` Right ()
                received <- Socket.recv served 1024
                received `shouldBe` Right (BS.pack "hello sink")
        it "given a file enumerator, when run into a collecting consumer, then the file contents round-trip" $ do
            writeFile roundTripFile "file body contents"
            final <- Stream.fileEnumerator roundTripFile (Iteratee.readBodyStrict bodyTooLarge 1000)
            result <- Iteratee.run final
            Directory.removeFile roundTripFile
            result `shouldBe` Right (BS.pack "file body contents")
        it "given a chunked file enumerator, when run into a chunk-counting consumer, then the file arrives in chunks of the requested size" $ do
            writeFile chunkedFile "twelve bytes"
            final <- Stream.fileEnumeratorChunked 5 chunkedFile countChunks
            result <- Iteratee.run final
            Directory.removeFile chunkedFile
            result `shouldBe` Right [5, 5, 2]
        it "given a source file, when copied, then the destination holds the same bytes" $ do
            writeFile chunkedFile "bytes to copy across"
            outcome <- Stream.copyFile chunkedFile copiedFile
            copied <- BS.readFile copiedFile
            Directory.removeFile chunkedFile
            Directory.removeFile copiedFile
            outcome `shouldBe` Right ()
            copied `shouldBe` BS.pack "bytes to copy across"
        it "given a missing source, when copied, then the copy fails with a source error" $ do
            outcome <- Stream.copyFile missingFile copiedFile
            exists <- Directory.doesFileExist copiedFile
            Monad.when exists (Directory.removeFile copiedFile)
            isSourceError outcome `shouldBe` True
        it "given a file that does not exist, when enumerated, then the consumer sees a source error" $ do
            final <- Stream.fileEnumerator missingFile (Iteratee.readBodyStrict bodyTooLarge 1000)
            result <- Iteratee.run final
            isSourceError result `shouldBe` True

-- | Collects the byte length of each chunk fed until end of stream.
countChunks :: Iteratee.Iter Stream.StreamError [Int]
countChunks = go []
  where
    go acc = Iteratee.NeedInput $ \stream -> case stream of
        Iteratee.Chunk bytes -> go (BS.length bytes : acc)
        Iteratee.EndOfStream Nothing -> Iteratee.Done (reverse acc) stream
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err stream

chunkedFile :: FilePath
chunkedFile = "build/streamspec-chunked.txt"

copiedFile :: FilePath
copiedFile = "build/streamspec-copied.txt"

bodyTooLarge :: Stream.StreamError
bodyTooLarge = Stream.StreamParseError Parse.BodyTooLarge

isSourceError :: Either Stream.StreamError a -> Bool
isSourceError (Left (Stream.StreamSourceError _)) = True
isSourceError _ = False

roundTripFile :: FilePath
roundTripFile = "build/stream-roundtrip.tmp"

missingFile :: FilePath
missingFile = "build/stream-does-not-exist.tmp"

loopback :: Socket.Host
loopback = Socket.HostIPv4 127 0 0 1

withConnectedPair :: (Socket.ClientSocket -> Socket.ClientSocket -> IO ()) -> IO ()
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
                                Right (served, _conn) -> do
                                    use client served
                                    _ <- Socket.closeClientSocket served
                                    _ <- Socket.closeClientSocket client
                                    return ()
            closed <- Socket.closeListenSocket socket
            closed `shouldBe` Right ()
