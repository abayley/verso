module MicroHttp.MiddlewareSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Middleware as Middleware
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Stream as Stream
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Middleware" $ do
        it "given head-level middleware, when wrapping an application, then the response is transformed" $ do
            response <- runApp "" (Middleware.mapResponse withMarker echoStatus)
            fmap Http.responseHeaders response `shouldBe` Right [(Http.normaliseHeaderName (bs "X-Marker"), bs "on")]
        it "given ingress middleware bounding the body, when the handler reads, then it sees only the bounded bytes" $ do
            response <- runApp "hello" (Middleware.ingress (Iteratee.takeN 2) echoBody)
            fmap Http.responseBody response `shouldBe` Right (Http.StrictBody (bs "he"))
        it "given egress middleware bounding the body, when the response streams, then the sink sees only the bounded bytes" $ do
            response <- runApp "" (Middleware.egress (Iteratee.takeN 3) streamHello)
            case response of
                Left err -> expect ("unexpected failure: " ++ show err) False
                Right ok -> do
                    chunks <- recordBody ok
                    chunks `shouldBe` Right [bs "hel"]
        it "given failure-handling middleware, when the application fails, then the replacement response is returned" $ do
            response <- runApp "x" (Middleware.catchIter (const errorResponse) alwaysFails)
            fmap (Http.statusCode . Http.responseStatus) response `shouldBe` Right 500

-- Applications under test. Each ignores the connection and reads the stream.

echoStatus :: Http.Application
echoStatus _ = pure (Http.Response Http.okStatus [] (Http.StrictBody (bs "ok")))

echoBody :: Http.Application
echoBody _ = do
    body <- Iteratee.readBodyStrict (Stream.StreamParseError (Http.BadRequest "too large")) 100
    pure (Http.Response Http.okStatus [] (Http.StrictBody body))

streamHello :: Http.Application
streamHello _ = pure (Http.Response Http.okStatus [] (Http.StreamBody (Iteratee.strictEnumerator (bs "hello"))))

alwaysFails :: Http.Application
alwaysFails _ = Iteratee.readBodyStrict (Stream.StreamParseError (Http.BadRequest "boom")) 0 >> pure (Http.Response Http.okStatus [] (Http.StrictBody (bs "unreached")))

withMarker :: Http.Response -> Http.Response
withMarker response =
    response{Http.responseHeaders = [(Http.normaliseHeaderName (bs "X-Marker"), bs "on")]}

errorResponse :: Http.Response
errorResponse =
    Http.Response (Http.Status 500 "Internal Server Error") [] (Http.StrictBody (bs "error"))

-- Harness.

runApp :: String -> Http.Application -> IO (Either Stream.StreamError Http.Response)
runApp body app = Iteratee.strictEnumerator (bs body) (app conn) >>= Iteratee.run

conn :: Socket.ConnectionInfo
conn = Socket.ConnectionInfo (Socket.HostIPv4 127 0 0 1) (Socket.Port 0)

recordBody :: Http.Response -> IO (Either Stream.StreamError [BS.ByteString])
recordBody response =
    case Http.responseBody response of
        Http.StrictBody _ -> return (Right [])
        Http.StreamBody enumerator -> do
            chunks <- IORef.newIORef []
            final <- enumerator (Iteratee.byteSinkI (recordChunk chunks))
            outcome <- Iteratee.run final
            case outcome of
                Left err -> return (Left err)
                Right () -> do
                    values <- IORef.readIORef chunks
                    return (Right (reverse values))

recordChunk :: IORef.IORef [BS.ByteString] -> BS.ByteString -> IO (Either Stream.StreamError ())
recordChunk chunks chunk = do
    IORef.modifyIORef chunks (chunk :)
    return (Right ())

bs :: String -> BS.ByteString
bs = BS.pack
