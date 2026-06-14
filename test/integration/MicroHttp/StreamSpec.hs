module MicroHttp.StreamSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http.Parser (ParseError (..))
import MicroHttp.Iteratee (readBodyStrict, run, strictEnumerator, takeN)
import MicroHttp.Network.Socket
import MicroHttp.Stream
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Stream producers" $ do
        it "given a socket enumerator and a bound, when a body is streamed through takeN to a collecting consumer, then the bounded bytes round-trip" $
            withConnectedPair $ \client served -> do
                let payload = replicate 5000 'x' ++ replicate 100 'y'
                sent <- sendAll client (BS.pack payload)
                sent `shouldBe` Right ()
                final <- socketEnumerator served 1024 0 (takeN 5000 (readBodyStrict bodyTooLarge 100000))
                result <- run final
                fmap BS.length result `shouldBe` Right 5000
        it "given a socket sink, when a strict body is streamed into it, then the peer receives the bytes" $
            withConnectedPair $ \client served -> do
                final <- strictEnumerator (BS.pack "hello sink") (socketSinkI client)
                result <- run final
                result `shouldBe` Right ()
                received <- recv served 1024
                received `shouldBe` Right (BS.pack "hello sink")
        it "given a file enumerator, when run into a collecting consumer, then the file contents round-trip" $ do
            writeFile roundTripFile "file body contents"
            final <- fileEnumerator roundTripFile (readBodyStrict bodyTooLarge 1000)
            result <- run final
            removeFile roundTripFile
            result `shouldBe` Right (BS.pack "file body contents")
        it "given a file that does not exist, when enumerated, then the consumer sees a source error" $ do
            final <- fileEnumerator missingFile (readBodyStrict bodyTooLarge 1000)
            result <- run final
            isSourceError result `shouldBe` True

bodyTooLarge :: StreamError
bodyTooLarge = StreamParseError BodyTooLarge

isSourceError :: Either StreamError a -> Bool
isSourceError (Left (StreamSourceError _)) = True
isSourceError _ = False

roundTripFile :: FilePath
roundTripFile = "build/stream-roundtrip.tmp"

missingFile :: FilePath
missingFile = "build/stream-does-not-exist.tmp"

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
                                Right (served, _conn) -> do
                                    use client served
                                    _ <- closeClientSocket served
                                    _ <- closeClientSocket client
                                    return ()
            closed <- closeListenSocket socket
            closed `shouldBe` Right ()
