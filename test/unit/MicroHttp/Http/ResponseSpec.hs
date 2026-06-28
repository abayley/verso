module MicroHttp.Http.ResponseSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Response" $ do
        it "given strict text response, when serialising, then HTTP response bytes are returned" $
            Http.serialiseResponse (Http.Response Http.okStatus [] (Http.StrictBody (bs "hello")))
                `shouldBe` Right (bs "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        it "given response headers, when serialising, then headers are emitted before computed headers" $
            Http.serialiseResponse
                ( Http.Response
                    Http.okStatus
                    [(Http.normaliseHeaderName (bs "Content-Type"), bs "text/plain")]
                    (Http.StrictBody (bs "ok"))
                )
                `shouldBe` Right (bs "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        it "given streaming body response, when pure serialising, then stream body error is returned" $
            Http.serialiseResponse (Http.Response Http.okStatus [] (Http.StreamBody (Iteratee.strictEnumerator (bs "x"))))
                `shouldBe` Left Http.CannotSerialiseStreamBody
        it "given file body response, when pure serialising, then a serialise error is returned" $
            Http.serialiseResponse (Http.Response Http.okStatus [] (Http.FileBody "x.txt" 3))
                `shouldBe` Left Http.CannotSerialiseStreamBody
        it "given a file head with a size, when serialising, then headers and an exact Content-Length are emitted" $
            Http.serialiseFileHead
                (Http.Response Http.okStatus [(Http.normaliseHeaderName (bs "Content-Type"), bs "text/plain")] (Http.FileBody "x.txt" 12))
                12
                `shouldBe` bs "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nContent-Length: 12\r\nConnection: close\r\n\r\n"
        it "given strict body response, when writing, then serialised response is written" $ do
            strictChunks <- recordResponse (Http.Response Http.okStatus [] (Http.StrictBody (bs "ok")))
            strictChunks
                `shouldBe` Right [bs "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"]
        it "given streaming body response, when writing, then head and body chunks are written" $ do
            streamChunks <- recordResponse (Http.Response Http.okStatus [] (Http.StreamBody (Iteratee.strictEnumerator (bs "streamed"))))
            streamChunks
                `shouldBe` Right [bs "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", bs "streamed"]

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
read and replayed through the same writer (the non-zero-copy test fallback).
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
