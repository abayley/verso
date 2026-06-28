module MicroHttp.Http.ResponseFileSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Http
import MicroHttp.Stream (StreamError, fileEnumerator)
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Response file bodies" $ do
        it "given a streaming file body response, when writing, then header and file chunks are written" $ do
            BS.writeFile responseFile (bs "file-body")
            fileChunks <- recordResponse (Response okStatus [] (StreamBody (fileEnumerator responseFile)))
            removeFile responseFile
            fileChunks
                `shouldBe` Right [bs "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", bs "file-body"]
        it "given a file body response, when writing, then a head with an exact Content-Length and the file bytes are written" $ do
            BS.writeFile responseFile (bs "file-body")
            fileChunks <- recordResponse (Response okStatus [] (FileBody responseFile 9))
            removeFile responseFile
            fileChunks
                `shouldBe` Right
                    [ bs "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\n"
                    , bs "file-body"
                    ]

responseFile :: FilePath
responseFile = "response-writer-test.tmp"

recordResponse :: Response -> IO (Either StreamError [BS.ByteString])
recordResponse response = do
    chunks <- newIORef []
    written <- writeResponse (memorySink (recordChunk chunks)) response
    case written of
        Left err -> return (Left err)
        Right () -> do
            values <- readIORef chunks
            return (Right (reverse values))

{- | An in-memory sink: chunks record through the writer, and a file body is
read and replayed through the same writer (the non-zero-copy test fallback that
keeps 'writeResponse' exercisable off a socket).
-}
memorySink :: ResponseWriter -> ResponseSink
memorySink writer = ResponseSink writer (memorySinkFile writer)

memorySinkFile :: ResponseWriter -> Response -> FilePath -> Int -> IO (Either StreamError ())
memorySinkFile writer response path size = do
    bytes <- BS.readFile path
    sentHead <- writer (serialiseFileHead response size)
    case sentHead of
        Left err -> return (Left err)
        Right () -> writer bytes

recordChunk :: IORef [BS.ByteString] -> BS.ByteString -> IO (Either StreamError ())
recordChunk chunks chunk = do
    modifyIORef chunks (chunk :)
    return (Right ())

bs :: String -> BS.ByteString
bs = BS.pack
