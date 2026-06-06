module Main(main) where

import Data.IORef
import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Http.Response
import System.Directory(removeFile)
import Test.Hspec

main :: IO ()
main = hspec $
  describe "MicroHttp.Http.Response" $ do
    it "given strict text response, when serialising, then HTTP response bytes are returned" $
      serialiseResponse (Response okStatus [] (StrictBody (bs "hello")))
        `shouldBe`
          Right (bs "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
    it "given response headers, when serialising, then headers are emitted before computed headers" $
      serialiseResponse
        (Response
          okStatus
          [(normaliseHeaderName (bs "Content-Type"), bs "text/plain")]
          (StrictBody (bs "ok")))
        `shouldBe`
          Right (bs "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    it "given file body response, when pure serialising, then file body error is returned" $
      serialiseResponse (Response okStatus [] (FileBody "public/app.css"))
        `shouldBe` Left CannotSerialiseFileBody
    it "given strict body response, when writing, then serialised response is written" $ do
      strictChunks <- recordResponse (Response okStatus [] (StrictBody (bs "ok")))
      strictChunks
        `shouldBe`
          Right [bs "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"]
    it "given file body response, when writing, then header and file chunks are written" $ do
      BS.writeFile responseFile (bs "file-body")
      fileChunks <- recordResponse (Response okStatus [] (FileBody responseFile))
      removeFile responseFile
      fileChunks
        `shouldBe`
          Right [bs "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", bs "file-body"]

responseFile :: FilePath
responseFile = "response-writer-test.tmp"

recordResponse :: Response -> IO (Either ResponseWriteError [BS.ByteString])
recordResponse response = do
  chunks <- newIORef []
  written <- writeResponse (recordChunk chunks) response
  case written of
    Left err -> return (Left err)
    Right () -> do
      values <- readIORef chunks
      return (Right (reverse values))

recordChunk :: IORef [BS.ByteString] -> BS.ByteString -> IO (Either ResponseWriteError ())
recordChunk chunks chunk = do
  modifyIORef chunks (chunk :)
  return (Right ())

bs :: String -> BS.ByteString
bs = BS.pack
