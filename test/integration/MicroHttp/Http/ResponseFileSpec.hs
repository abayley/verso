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

memorySinkFile :: Http.ResponseWriter -> Http.Response -> FilePath -> Int -> IO (Either Stream.StreamError ())
memorySinkFile writer response path size = do
    bytes <- BS.readFile path
    sentHead <- writer (Http.serialiseFileHead response size)
    case sentHead of
        Left err -> return (Left err)
        Right () -> writer bytes

recordChunk :: IORef.IORef [BS.ByteString] -> BS.ByteString -> IO (Either Stream.StreamError ())
recordChunk chunks chunk = do
    IORef.modifyIORef chunks (chunk :)
    return (Right ())

bs :: String -> BS.ByteString
bs = BS.pack
