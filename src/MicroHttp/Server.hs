module MicroHttp.Server (
    Application,
    ServerError (..),
    Settings (..),
    defaultSettings,
    handleClient,
    respondToRequestBytes,
    serve,
    serveOne,
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.QSem
import qualified Data.ByteString.Char8 as BS
import Data.Char (isDigit)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import MicroHttp.Http
import MicroHttp.Http.Framing
import MicroHttp.Http.Parser (ParseError (..), ParseLimits (..), parseRequestHead)
import MicroHttp.Http.Response
import MicroHttp.Iteratee (Iter (..), Stream (..), run, strictEnumerator, takeN)
import MicroHttp.Log (AccessEvent (..), Logger, nullLogger)
import MicroHttp.Network.Socket
import MicroHttp.Stream (StreamError (..), socketEnumerator)
import System.IO.TimeMilli (getTimeMilli)

{- | A request handler: it consumes the request body as a stream and yields
a response.
-}
type Application = RequestHead -> Iter StreamError Response

data Settings = Settings
    { settingsHost :: Host
    , settingsPort :: Port
    , settingsBacklog :: Int
    , settingsMaxActiveHandlers :: Int
    , settingsMaxHeaderBytes :: Int
    , settingsMaxBodyBytes :: Int
    , settingsReadBufferBytes :: Int
    , settingsIdleReadTimeoutMicros :: Int
    , settingsIdleWriteTimeoutMicros :: Int
    , settingsLogger :: Logger
    }

defaultSettings :: Settings
defaultSettings =
    Settings
        { settingsHost = HostAny
        , settingsPort = Port 8080
        , settingsBacklog = 16
        , settingsMaxActiveHandlers = 32
        , settingsMaxHeaderBytes = 8192
        , settingsMaxBodyBytes = 1048576
        , settingsReadBufferBytes = 8192
        , settingsIdleReadTimeoutMicros = 30000000
        , settingsIdleWriteTimeoutMicros = 30000000
        , settingsLogger = nullLogger
        }

data ServerError
    = ServerListenFailed SocketError
    | ServerAcceptFailed SocketError
    | ServerReadFailed SocketError
    | ServerWriteFailed StreamError
    deriving (Eq, Show)

serve :: Settings -> Application -> IO (Either ServerError ())
serve settings app = do
    opened <-
        listenTcp
            (settingsHost settings)
            (settingsPort settings)
            (settingsBacklog settings)
    case opened of
        Left err -> return (Left (ServerListenFailed err))
        Right socket -> do
            sem <- newQSem (settingsMaxActiveHandlers settings)
            acceptLoop settings app sem socket

serveOne :: Settings -> Application -> IO (Either ServerError ())
serveOne settings app = do
    opened <-
        listenTcp
            (settingsHost settings)
            (settingsPort settings)
            (settingsBacklog settings)
    case opened of
        Left err -> return (Left (ServerListenFailed err))
        Right socket -> do
            result <- acceptAndHandle settings app socket
            _ <- closeListenSocket socket
            return result

{- | Drives the request pipeline over an in-memory copy of the request
bytes, returning the application response (or a 400 on a framing, parse, or
limit failure). The unit-test seam for the application boundary.
-}
respondToRequestBytes :: Settings -> Application -> BS.ByteString -> IO Response
respondToRequestBytes settings app bytes = do
    final <- strictEnumerator bytes (requestPipeline settings (const (pure ())) app)
    outcome <- run final
    case outcome of
        Left _ -> return badRequestResponse
        Right response -> return response

acceptLoop :: Settings -> Application -> QSem -> ListenSocket -> IO (Either ServerError ())
acceptLoop settings app sem socket = do
    accepted <- accept socket
    case accepted of
        Left err -> return (Left (ServerAcceptFailed err))
        Right client -> do
            _ <- forkIO (runCappedHandler settings app sem client)
            acceptLoop settings app sem socket

runCappedHandler :: Settings -> Application -> QSem -> ClientSocket -> IO ()
runCappedHandler settings app sem client = do
    waitQSem sem
    _ <- handleClient settings app client
    signalQSem sem

acceptAndHandle :: Settings -> Application -> ListenSocket -> IO (Either ServerError ())
acceptAndHandle settings app socket = do
    accepted <- accept socket
    case accepted of
        Left err -> return (Left (ServerAcceptFailed err))
        Right client -> handleClient settings app client

handleClient :: Settings -> Application -> ClientSocket -> IO (Either ServerError ())
handleClient settings app client = do
    let logger = settingsLogger settings
    startMillis <- getTimeMilli
    headRef <- newIORef Nothing
    bytesRef <- newIORef 0
    final <-
        socketEnumerator
            client
            (settingsReadBufferBytes settings)
            (settingsIdleReadTimeoutMicros settings)
            (requestPipeline settings (onHead logger headRef) app)
    outcome <- run final
    result <- respondToOutcome settings bytesRef client outcome
    endMillis <- getTimeMilli
    capturedHead <- readIORef headRef
    bytesWritten <- readIORef bytesRef
    logCompletion logger capturedHead outcome result bytesWritten (endMillis - startMillis)
    _ <- closeClientSocket client
    return result

{- | The @onHead@ callback for the request pipeline: it records the parsed
head for the completion line and emits the 'RequestReceived' event the moment
the head is available.
-}
onHead :: Logger -> IORef (Maybe RequestHead) -> RequestHead -> IO ()
onHead logger headRef head = do
    writeIORef headRef (Just head)
    logger (RequestReceived head)

{- | Emits the terminal access-log event: a 'RequestCompleted' carrying the
written response's status when a response was sent (including the 400 and 408
paths), or a 'RequestAborted' with an error label when the connection failed
without a clean response.
-}
logCompletion :: Logger -> Maybe RequestHead -> Either StreamError Response -> Either ServerError () -> Int -> Int -> IO ()
logCompletion logger capturedHead outcome result bytesWritten durationMillis =
    case result of
        Left err -> logger (RequestAborted capturedHead (abortLabel err) durationMillis)
        Right () -> logger (RequestCompleted capturedHead (writtenStatus outcome) bytesWritten durationMillis)

-- | The status written for a successful response outcome.
writtenStatus :: Either StreamError Response -> Status
writtenStatus outcome =
    case outcome of
        Right response -> responseStatus response
        Left StreamTimeout -> responseStatus requestTimeoutResponse
        Left _ -> responseStatus badRequestResponse

-- | A short, space-free label naming the failure for the aborted log line.
abortLabel :: ServerError -> String
abortLabel err =
    case err of
        ServerListenFailed _ -> "ServerListenFailed"
        ServerAcceptFailed _ -> "ServerAcceptFailed"
        ServerReadFailed _ -> "ServerReadFailed"
        ServerWriteFailed _ -> "ServerWriteFailed"

{- | The per-connection request pipeline: frame the headers, parse the head,
then run the application with the body stream framed to the declared
@Content-Length@. The body bound terminates the application's body read
without waiting for the peer to close, and rejecting an over-declared or
malformed length is done before any body byte is read.
-}
requestPipeline :: Settings -> (RequestHead -> IO ()) -> Application -> Iter StreamError Response
requestPipeline settings notifyHead app =
    frameHeadersI (parseLimits settings) >>= dispatch
  where
    dispatch headerBytes =
        case parseRequestHead headerBytes of
            Left err -> failWith (StreamParseError err)
            Right head -> IterM (notifyHead head >> pure (withBody head))
    withBody head =
        case declaredContentLength (requestHeaders head) of
            Left err -> failWith (StreamParseError err)
            Right bodyLength
                | bodyLength > settingsMaxBodyBytes settings ->
                    failWith (StreamParseError BodyTooLarge)
                | otherwise -> takeN bodyLength (app head)

{- | Writes the response for a completed request, or maps a transport read
failure to a server error. An idle-read timeout is answered with a 408; a
framing, parse, or limit failure with a 400, matching the previous
malformed-request handling.
-}
respondToOutcome :: Settings -> IORef Int -> ClientSocket -> Either StreamError Response -> IO (Either ServerError ())
respondToOutcome settings bytesRef client outcome =
    case outcome of
        Left (StreamReadError err) -> return (Left (ServerReadFailed err))
        Left StreamTimeout -> writeClientResponse settings bytesRef client requestTimeoutResponse
        Left _ -> writeClientResponse settings bytesRef client badRequestResponse
        Right response -> writeClientResponse settings bytesRef client response

writeClientResponse :: Settings -> IORef Int -> ClientSocket -> Response -> IO (Either ServerError ())
writeClientResponse settings bytesRef client response = do
    written <- writeResponse (socketResponseWriter settings bytesRef client) response
    case written of
        Left err -> return (Left (ServerWriteFailed err))
        Right () -> return (Right ())

{- | The socket response writer, counting the bytes it sends into @bytesRef@
for the access log. A chunk is counted only once its send succeeds, so the
count reflects bytes actually put on the wire.
-}
socketResponseWriter :: Settings -> IORef Int -> ClientSocket -> ResponseWriter
socketResponseWriter settings bytesRef client bytes = do
    sent <- sendAllWithin (settingsIdleWriteTimeoutMicros settings) client bytes
    case sent of
        Left err -> return (Left (StreamWriteError err))
        Right () -> do
            modifyIORef' bytesRef (+ BS.length bytes)
            return (Right ())

parseLimits :: Settings -> ParseLimits
parseLimits settings =
    ParseLimits
        { maxHeaderBytes = settingsMaxHeaderBytes settings
        , maxBodyBytes = settingsMaxBodyBytes settings
        }

{- | A pipeline failure becomes an iteratee failure; the residue is empty
because the body is not consumed on the failure path.
-}
failWith :: StreamError -> Iter StreamError Response
failWith err = IterFailed err (Chunk BS.empty)

{- | The declared body length: a missing @Content-Length@ means no body,
a well-formed value is its length, and a non-numeric value is rejected.
-}
declaredContentLength :: Headers -> Either ParseError Int
declaredContentLength headers =
    case lookupHeaderValue "content-length" headers of
        Nothing -> Right 0
        Just value
            | value /= "" && all isDigit value -> Right (read value)
            | otherwise -> Left (BadRequest "invalid content-length")

lookupHeaderValue :: String -> Headers -> Maybe String
lookupHeaderValue _ [] = Nothing
lookupHeaderValue name ((key, value) : rest)
    | normaliseHeaderName (BS.pack name) == key = Just (BS.unpack value)
    | otherwise = lookupHeaderValue name rest

badRequestResponse :: Response
badRequestResponse =
    Response
        (Status 400 "Bad Request")
        [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (StrictBody (BS.pack "bad request\n"))

requestTimeoutResponse :: Response
requestTimeoutResponse =
    Response
        (Status 408 "Request Timeout")
        [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (StrictBody (BS.pack "request timeout\n"))
