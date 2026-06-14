module MicroHttp.Http.ResponseSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Http
import MicroHttp.Http.Response
import MicroHttp.Iteratee (strictEnumerator)
import MicroHttp.Stream (StreamError)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Response" $ do
        it "given strict text response, when serialising, then HTTP response bytes are returned" $
            serialiseResponse (Response okStatus [] (StrictBody (bs "hello")))
                `shouldBe` Right (bs "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        it "given response headers, when serialising, then headers are emitted before computed headers" $
            serialiseResponse
                ( Response
                    okStatus
                    [(normaliseHeaderName (bs "Content-Type"), bs "text/plain")]
                    (StrictBody (bs "ok"))
                )
                `shouldBe` Right (bs "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        it "given streaming body response, when pure serialising, then stream body error is returned" $
            serialiseResponse (Response okStatus [] (StreamBody (strictEnumerator (bs "x"))))
                `shouldBe` Left CannotSerialiseStreamBody
        it "given file body response, when pure serialising, then a serialise error is returned" $
            serialiseResponse (Response okStatus [] (FileBody "x.txt" 3))
                `shouldBe` Left CannotSerialiseStreamBody
        it "given a file head with a size, when serialising, then headers and an exact Content-Length are emitted" $
            serialiseFileHead
                (Response okStatus [(normaliseHeaderName (bs "Content-Type"), bs "text/plain")] (FileBody "x.txt" 12))
                12
                `shouldBe` bs "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nContent-Length: 12\r\nConnection: close\r\n\r\n"
        it "given strict body response, when writing, then serialised response is written" $ do
            strictChunks <- recordResponse (Response okStatus [] (StrictBody (bs "ok")))
            strictChunks
                `shouldBe` Right [bs "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"]
        it "given streaming body response, when writing, then head and body chunks are written" $ do
            streamChunks <- recordResponse (Response okStatus [] (StreamBody (strictEnumerator (bs "streamed"))))
            streamChunks
                `shouldBe` Right [bs "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", bs "streamed"]

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
read and replayed through the same writer (the non-zero-copy test fallback).
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
