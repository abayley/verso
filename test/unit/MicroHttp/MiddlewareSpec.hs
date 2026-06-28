module MicroHttp.MiddlewareSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Http
import MicroHttp.Iteratee (byteSinkI, readBodyStrict, run, strictEnumerator, takeN)
import MicroHttp.Middleware
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import MicroHttp.Stream (StreamError (..))
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Middleware" $ do
        it "given head-level middleware, when wrapping an application, then the response is transformed" $ do
            response <- runApp "" (mapResponse withMarker echoStatus)
            fmap responseHeaders response `shouldBe` Right [(normaliseHeaderName (bs "X-Marker"), bs "on")]
        it "given ingress middleware bounding the body, when the handler reads, then it sees only the bounded bytes" $ do
            response <- runApp "hello" (ingress (takeN 2) echoBody)
            fmap responseBody response `shouldBe` Right (StrictBody (bs "he"))
        it "given egress middleware bounding the body, when the response streams, then the sink sees only the bounded bytes" $ do
            response <- runApp "" (egress (takeN 3) streamHello)
            case response of
                Left err -> expect ("unexpected failure: " ++ show err) False
                Right ok -> do
                    chunks <- recordBody ok
                    chunks `shouldBe` Right [bs "hel"]
        it "given failure-handling middleware, when the application fails, then the replacement response is returned" $ do
            response <- runApp "x" (catchIter (const errorResponse) alwaysFails)
            fmap (statusCode . responseStatus) response `shouldBe` Right 500

-- Applications under test. Each ignores the connection and reads the stream.

echoStatus :: Application
echoStatus _ = pure (Response okStatus [] (StrictBody (bs "ok")))

echoBody :: Application
echoBody _ = do
    body <- readBodyStrict (StreamParseError (BadRequest "too large")) 100
    pure (Response okStatus [] (StrictBody body))

streamHello :: Application
streamHello _ = pure (Response okStatus [] (StreamBody (strictEnumerator (bs "hello"))))

alwaysFails :: Application
alwaysFails _ = readBodyStrict (StreamParseError (BadRequest "boom")) 0 >> pure (Response okStatus [] (StrictBody (bs "unreached")))

withMarker :: Response -> Response
withMarker response =
    response{responseHeaders = [(normaliseHeaderName (bs "X-Marker"), bs "on")]}

errorResponse :: Response
errorResponse =
    Response (Status 500 "Internal Server Error") [] (StrictBody (bs "error"))

-- Harness.

runApp :: String -> Application -> IO (Either StreamError Response)
runApp body app = strictEnumerator (bs body) (app conn) >>= run

conn :: ConnectionInfo
conn = ConnectionInfo (HostIPv4 127 0 0 1) (Port 0)

recordBody :: Response -> IO (Either StreamError [BS.ByteString])
recordBody response =
    case responseBody response of
        StrictBody _ -> return (Right [])
        StreamBody enumerator -> do
            chunks <- newIORef []
            final <- enumerator (byteSinkI (recordChunk chunks))
            outcome <- run final
            case outcome of
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
