module MicroHttp.Http.ResponseFileSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Http
import MicroHttp.Http.Response
import MicroHttp.Stream (StreamError, fileEnumerator)
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Response file bodies" $
        it "given a streaming file body response, when writing, then header and file chunks are written" $ do
            BS.writeFile responseFile (bs "file-body")
            fileChunks <- recordResponse (Response okStatus [] (StreamBody (fileEnumerator responseFile)))
            removeFile responseFile
            fileChunks
                `shouldBe` Right [bs "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", bs "file-body"]

responseFile :: FilePath
responseFile = "response-writer-test.tmp"

recordResponse :: Response -> IO (Either StreamError [BS.ByteString])
recordResponse response = do
    chunks <- newIORef []
    written <- writeResponse (recordChunk chunks) response
    case written of
        Left err -> return (Left err)
        Right () -> do
            values <- readIORef chunks
            return (Right (reverse values))

recordChunk :: IORef [BS.ByteString] -> BS.ByteString -> IO (Either StreamError ())
recordChunk chunks chunk = do
    modifyIORef chunks (chunk :)
    return (Right ())

bs :: String -> BS.ByteString
bs = BS.pack
