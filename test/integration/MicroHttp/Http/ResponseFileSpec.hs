module MicroHttp.Http.ResponseFileSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Response file bodies" $ do
        it "given a streaming file body response, when writing, then header and file chunks are written" $ do
            BS.writeFile responseFile (bs "file-body")
            fileChunks <- recordResponse (Http.Response Http.okStatus [] (Http.StreamBody (Stream.fileEnumerator responseFile)))
            Directory.removeFile responseFile
            fileChunks
                `shouldBe` Right [bs "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", bs "file-body"]
        it "given a file body response, when writing, then a head with an exact Content-Length and the file bytes are written" $ do
            BS.writeFile responseFile (bs "file-body")
            fileChunks <- recordResponse (Http.Response Http.okStatus [] (Http.FileBody responseFile 9))
            Directory.removeFile responseFile
            fileChunks
                `shouldBe` Right
                    [ bs "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\n"
                    , bs "file-body"
                    ]

        describe "transformedFileResponse (RFC-0049)" $ do
            it "given a file streamed through a length-changing transform, when built and written, then the head carries the exact Content-Length and the body is prefix, transformed blocks, suffix" $ do
                BS.writeFile responseFile (bs "abc")
                built <- Http.transformedFileResponse Http.okStatus [] (bs "P") appendBang responseFile (bs "S")
                chunks <- either (pure . Left) recordResponse built
                Directory.removeFile responseFile
                chunks
                    `shouldBe` Right
                        [ bs "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\n"
                        , bs "P"
                        , bs "abc!"
                        , bs "S"
                        ]
            it "given a file that does not exist, when a response is built, then the count fails and a Left is returned before any head is written" $ do
                built <- Http.transformedFileResponse Http.okStatus [] (bs "P") appendBang "no-such-response-file.tmp" (bs "S")
                isLeft built `shouldBe` True

        describe "transformedTempFileResponse (RFC-0049)" $ do
            it "given a temp capture, when the body has been written, then the file is removed" $ do
                BS.writeFile responseFile (bs "abc")
                built <- Http.transformedTempFileResponse Http.okStatus [] (bs "P") appendBang responseFile (bs "S")
                _ <- either (pure . Left) recordResponse built
                Directory.doesFileExist responseFile `shouldReturn` False
            it "given a temp capture that does not exist, when a response is built, then a Left is returned" $ do
                built <- Http.transformedTempFileResponse Http.okStatus [] (bs "P") appendBang "no-such-temp-file.tmp" (bs "S")
                isLeft built `shouldBe` True

        describe "transformedBytesResponse (RFC-0049)" $ do
            it "given in-memory content through a transform, when built and written, then the head carries the exact Content-Length and the body is prefix, transformed content, suffix as one segment" $ do
                built <- Http.transformedBytesResponse Http.okStatus [] (bs "P") applyBang (bs "abc") (bs "S")
                chunks <- recordResponse built
                chunks
                    `shouldBe` Right
                        [ bs "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\n"
                        , bs "Pabc!S"
                        ]

-- | A length-changing block transform for the tests: append @!@ to each block, and its matching length.
appendBang :: Http.BlockTransform
appendBang = Http.BlockTransform 65536 applyBang (\b -> pure (BS.length b + 1))

-- | The transform half of 'appendBang'.
applyBang :: BS.ByteString -> IO BS.ByteString
applyBang b = pure (BS.append b (bs "!"))

-- | Whether an 'Either' is a 'Left'.
isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

responseFile :: FilePath
responseFile = "response-writer-test.tmp"

recordResponse :: Http.Response -> IO (Either Stream.StreamError [BS.ByteString])
recordResponse response = do
    chunks <- IORef.newIORef []
    written <- Http.writeResponse (memorySink (recordChunk chunks)) response
    case written of
        Left err -> return (Left err)
        Right () -> do
            values <- IORef.readIORef chunks
            return (Right (reverse values))

{- | An in-memory sink: chunks record through the writer, and a file body is
read and replayed through the same writer (the non-zero-copy test fallback that
keeps 'writeResponse' exercisable off a socket).
-}
memorySink :: Http.ResponseWriter -> Http.ResponseSink
memorySink writer = Http.ResponseSink writer (memorySinkFile writer)

memorySinkFile :: Http.ResponseWriter -> Http.Response -> FilePath -> IO (Either Stream.StreamError ())
memorySinkFile writer response path = do
    bytes <- BS.readFile path
    sentHead <- writer (Http.serialiseSizedHead response (BS.length bytes))
    case sentHead of
        Left err -> return (Left err)
        Right () -> writer bytes

recordChunk :: IORef.IORef [BS.ByteString] -> BS.ByteString -> IO (Either Stream.StreamError ())
recordChunk chunks chunk = do
    IORef.modifyIORef chunks (chunk :)
    return (Right ())

bs :: String -> BS.ByteString
bs = BS.pack
