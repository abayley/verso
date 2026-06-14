module MicroHttp.Server (
    Application,
    ServerError (..),
    Settings (..),
    defaultSettings,
    handleClient,
    parseLimits,
    respondToRequestBytes,
    serve,
    serveOne,
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.QSem
import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http (Response)
import MicroHttp.Http.Parser (ParseLimits (..))
import MicroHttp.Http.Response (ResponseSink (..), ResponseWriter, serialiseFileHead, writeResponse)
import MicroHttp.Iteratee (run, strictEnumerator)
import MicroHttp.Middleware (Application)
import MicroHttp.Network.Socket
import MicroHttp.Stream (StreamError (..), socketEnumerator)

{- | Server configuration. Pure, inert data: framing limits, the handler cap,
the read buffer, and the idle read/write timeouts. The access logger is no
longer here -- logging is a middleware (RFC-0012) the application composes.
-}
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
    }
    deriving (Eq, Show)

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
        }

data ServerError
    = ServerListenFailed SocketError
    | ServerAcceptFailed SocketError
    | ServerReadFailed SocketError
    | ServerWriteFailed StreamError
    | ServerStreamFailed StreamError
    deriving (Eq, Show)

-- | The 'ParseLimits' derived from settings, for an application's framing.
parseLimits :: Settings -> ParseLimits
parseLimits settings =
    ParseLimits
        { maxHeaderBytes = settingsMaxHeaderBytes settings
        , maxBodyBytes = settingsMaxBodyBytes settings
        }

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

{- | Drives an application over an in-memory copy of the request bytes with a
placeholder connection, returning the produced response or the stream failure.
The unit-test seam for the application boundary; compose the application with
'MicroHttp.Middleware.withErrorResponses' to exercise the 400/408 mapping.
-}
respondToRequestBytes :: Application -> BS.ByteString -> IO (Either StreamError Response)
respondToRequestBytes app bytes =
    strictEnumerator bytes (app placeholderConnection) >>= run

placeholderConnection :: ConnectionInfo
placeholderConnection = ConnectionInfo (HostIPv4 127 0 0 1) (Port 0)

acceptLoop :: Settings -> Application -> QSem -> ListenSocket -> IO (Either ServerError ())
acceptLoop settings app sem socket = do
    accepted <- accept socket
    case accepted of
        Left err -> return (Left (ServerAcceptFailed err))
        Right (client, conn) -> do
            _ <- forkIO (runCappedHandler settings app sem client conn)
            acceptLoop settings app sem socket

runCappedHandler :: Settings -> Application -> QSem -> ClientSocket -> ConnectionInfo -> IO ()
runCappedHandler settings app sem client conn = do
    waitQSem sem
    _ <- handleClient settings app client conn
    signalQSem sem

acceptAndHandle :: Settings -> Application -> ListenSocket -> IO (Either ServerError ())
acceptAndHandle settings app socket = do
    accepted <- accept socket
    case accepted of
        Left err -> return (Left (ServerAcceptFailed err))
        Right (client, conn) -> handleClient settings app client conn

{- | The connection layer: drive the application stack over the socket, write
the response it produced, and close. Framing, parsing, error-mapping, and
logging all live in the application stack (the router and middleware), not
here. A stream failure that produced no response (a read failure) closes the
connection with nothing written.
-}
handleClient :: Settings -> Application -> ClientSocket -> ConnectionInfo -> IO (Either ServerError ())
handleClient settings app client conn = do
    final <-
        socketEnumerator
            client
            (settingsReadBufferBytes settings)
            (settingsIdleReadTimeoutMicros settings)
            (app conn)
    outcome <- run final
    result <- case outcome of
        Right response -> writeClientResponse settings client response
        Left err -> return (Left (streamFailure err))
    _ <- closeClientSocketGraceful client
    return result

writeClientResponse :: Settings -> ClientSocket -> Response -> IO (Either ServerError ())
writeClientResponse settings client response = do
    written <- writeResponse (socketResponseSink settings client) response
    case written of
        Left err -> return (Left (ServerWriteFailed err))
        Right () -> return (Right ())

{- | The socket-backed response sink: chunks go out with 'sendAllWithin'; a file
body is sent zero-copy with 'sendfile' through 'socketSinkFile'.
-}
socketResponseSink :: Settings -> ClientSocket -> ResponseSink
socketResponseSink settings client =
    ResponseSink
        { sinkChunk = socketChunkWriter settings client
        , sinkFile = socketSinkFile settings client
        }

socketChunkWriter :: Settings -> ClientSocket -> ResponseWriter
socketChunkWriter settings client bytes = do
    sent <- sendAllWithin (settingsIdleWriteTimeoutMicros settings) client bytes
    case sent of
        Left err -> return (Left (StreamWriteError err))
        Right () -> return (Right ())

{- | Sends a file response zero-copy: open the file read-only, write the head
with the carried size as @Content-Length@, @sendfile@ the body, then close. The
size is the one resolved when the 'FileBody' was built, so no @lseek@ happens
here. An open failure -- a rare time-of-check/time-of-use race after
'MicroHttp.Static.serveStatic' already found the file -- aborts the connection,
like a streamed body that fails mid-flight.
-}
socketSinkFile :: Settings -> ClientSocket -> Response -> FilePath -> Int -> IO (Either StreamError ())
socketSinkFile settings client response path size = do
    opened <- openFileRead path
    case opened of
        Nothing -> return (Left (StreamSourceError ("cannot open file: " ++ path)))
        Just fd -> do
            result <- sendHeadThenFile settings client response fd size
            closeFileFd fd
            return result

sendHeadThenFile :: Settings -> ClientSocket -> Response -> FileFd -> Int -> IO (Either StreamError ())
sendHeadThenFile settings client response fd size = do
    sentHead <- socketChunkWriter settings client (serialiseFileHead response size)
    case sentHead of
        Left err -> return (Left err)
        Right () -> do
            sentBody <- sendFileWithin (settingsIdleWriteTimeoutMicros settings) client fd 0 size
            case sentBody of
                Left err -> return (Left (StreamWriteError err))
                Right () -> return (Right ())

streamFailure :: StreamError -> ServerError
streamFailure err =
    case err of
        StreamReadError socketError -> ServerReadFailed socketError
        _ -> ServerStreamFailed err
