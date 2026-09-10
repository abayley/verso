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
    serveWithReady,
) where

import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.QSem as QSem
import qualified Data.ByteString.Char8 as BS
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Ptr as Ptr
import MicroHttp.Http (Application)
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import MicroHttp.Settings (Settings (..), defaultSettings, parseLimits)
import qualified MicroHttp.Settings as Settings
import qualified MicroHttp.Stream as Stream
import qualified System.IO as IO

-- | Failure modes surfaced by the server while accepting, reading, or writing.
data ServerError
    = ServerListenFailed Socket.SocketError
    | ServerAcceptFailed Socket.SocketError
    | ServerReadFailed Socket.SocketError
    | ServerWriteFailed Stream.StreamError
    | ServerStreamFailed Stream.StreamError
    deriving (Eq, Show)

-- signal(2): ignore SIGPIPE process-wide so that a client disconnecting mid-response
-- (e.g. a browser that gave up on a slow operation) makes the socket write return an
-- error -- already handled per-connection as a SocketError -- instead of killing the
-- whole server with signal 13. SIG_IGN is the libc sentinel handler value @(void*)1@.
foreign import ccall "signal" c_signal :: CTypes.CInt -> Ptr.Ptr () -> IO (Ptr.Ptr ())

-- | Install SIG_IGN for SIGPIPE so writes to a dead socket fail rather than kill the process.
ignoreSigpipe :: IO ()
ignoreSigpipe = do
    _ <- c_signal sigPIPE sigIGN
    pure ()
  where
    sigPIPE = 13
    sigIGN = Ptr.nullPtr `Ptr.plusPtr` 1

-- | Open the listening socket and serve connections concurrently, capped by the handler semaphore.
serve :: Settings.Settings -> Http.Application -> IO (Either ServerError ())
serve settings = serveWithReady settings (\_ -> return ())

{- | 'serve', with an action run once the socket is bound and about to accept.

The caller announces the listen address from there rather than before calling, so a failed
bind is not preceded by a line claiming the server is up. The bound port is passed because
it is not always the configured one: port 0 asks the kernel to choose.
-}
serveWithReady ::
    Settings.Settings -> (Socket.Port -> IO ()) -> Http.Application -> IO (Either ServerError ())
serveWithReady settings ready app = do
    ignoreSigpipe
    opened <-
        Socket.listenTcp
            (Settings.settingsHost settings)
            (Settings.settingsPort settings)
            (Settings.settingsBacklog settings)
    case opened of
        Left err -> return (Left (ServerListenFailed err))
        Right socket -> do
            queried <- Socket.boundPort socket
            -- MicroHs has no Data.Either.fromRight, so this stays a case.
            ready (case queried of Right bound -> bound; Left _ -> Settings.settingsPort settings)
            sem <- QSem.newQSem (Settings.settingsMaxActiveHandlers settings)
            acceptLoop settings app sem socket

-- | Open the listening socket, handle a single connection, then close the socket.
serveOne :: Settings.Settings -> Http.Application -> IO (Either ServerError ())
serveOne settings app = do
    opened <-
        Socket.listenTcp
            (Settings.settingsHost settings)
            (Settings.settingsPort settings)
            (Settings.settingsBacklog settings)
    case opened of
        Left err -> return (Left (ServerListenFailed err))
        Right socket -> do
            result <- acceptAndHandle settings app socket
            _ <- Socket.closeListenSocket socket
            return result

{- | Drives an application over an in-memory copy of the request bytes with a
placeholder connection, returning the produced response or the stream failure.
The unit-test seam for the application boundary; compose the application with
'MicroHttp.Middleware.withErrorResponses' to exercise the 400/408 mapping.
-}
respondToRequestBytes :: Http.Application -> BS.ByteString -> IO (Either Stream.StreamError Http.Response)
respondToRequestBytes app bytes =
    Iteratee.strictEnumerator bytes (app placeholderConnection) >>= Iteratee.run

-- | A stand-in 'ConnectionInfo' (loopback, port 0) for driving applications without a real socket.
placeholderConnection :: Socket.ConnectionInfo
placeholderConnection = Socket.ConnectionInfo (Socket.HostIPv4 127 0 0 1) (Socket.Port 0)

-- | Accept connections forever, forking a capped handler for each accepted client.
acceptLoop :: Settings.Settings -> Http.Application -> QSem.QSem -> Socket.ListenSocket -> IO (Either ServerError ())
acceptLoop settings app sem socket = do
    accepted <- Socket.accept socket
    case accepted of
        Left err -> return (Left (ServerAcceptFailed err))
        Right (client, conn) -> do
            _ <- Concurrent.forkIO (runCappedHandler settings app sem client conn)
            acceptLoop settings app sem socket

-- | Handle one client while holding a semaphore slot, releasing it when done.
runCappedHandler :: Settings.Settings -> Http.Application -> QSem.QSem -> Socket.ClientSocket -> Socket.ConnectionInfo -> IO ()
runCappedHandler settings app sem client conn = do
    QSem.waitQSem sem
    result <- handleClient settings app client conn
    reportConnectionFailure conn result
    QSem.signalQSem sem

{- | Surfaces a connection-level failure (RFC-0032 robustness): a read/parse/write
or idle-timeout error that happens before or outside the application stack is
invisible to the request logger -- it never became a logged request -- and was
previously discarded silently. Logging it to stderr makes stalled or failing
connections visible (e.g. a flood of idle-read timeouts when clients connect but
no request is ever read). A successful exchange logs nothing here (the request
logger already recorded it). Note: a total event-manager wedge in which the read
never returns and the idle timer never fires cannot be reported from inside the
frozen runtime; that is an environmental fault, signalled by clients hanging with
no entries in either log.
-}
reportConnectionFailure :: Socket.ConnectionInfo -> Either ServerError () -> IO ()
reportConnectionFailure _ (Right ()) = pure ()
reportConnectionFailure conn (Left err) =
    IO.hPutStrLn IO.stderr ("micro-http: connection from " ++ showPeer conn ++ " failed: " ++ show err)

-- | Formats a peer as @a.b.c.d:port@ for connection diagnostics.
showPeer :: Socket.ConnectionInfo -> String
showPeer (Socket.ConnectionInfo host (Socket.Port port)) = showHost host ++ ":" ++ show port
  where
    showHost (Socket.HostIPv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
    showHost _ = "?"

-- | Accept a single connection and handle it inline.
acceptAndHandle :: Settings.Settings -> Http.Application -> Socket.ListenSocket -> IO (Either ServerError ())
acceptAndHandle settings app socket = do
    accepted <- Socket.accept socket
    case accepted of
        Left err -> return (Left (ServerAcceptFailed err))
        Right (client, conn) -> handleClient settings app client conn

{- | The connection layer: drive the application stack over the socket, write
the response it produced, and close. Framing, parsing, error-mapping, and
logging all live in the application stack (the router and middleware), not
here. A stream failure that produced no response (a read failure) closes the
connection with nothing written.
-}
handleClient :: Settings.Settings -> Http.Application -> Socket.ClientSocket -> Socket.ConnectionInfo -> IO (Either ServerError ())
handleClient settings app client conn = do
    final <-
        Stream.socketEnumerator
            client
            (Settings.settingsReadBufferBytes settings)
            (Settings.settingsIdleReadTimeoutMicros settings)
            (app conn)
    outcome <- Iteratee.run final
    result <- case outcome of
        Right response -> writeClientResponse settings client response
        Left err -> return (Left (streamFailure err))
    _ <- Socket.closeClientSocketGraceful client
    return result

-- | Write a response to the client socket, mapping any write failure to a 'ServerError'.
writeClientResponse :: Settings.Settings -> Socket.ClientSocket -> Http.Response -> IO (Either ServerError ())
writeClientResponse settings client response = do
    written <- Http.writeResponse (socketResponseSink settings client) response
    case written of
        Left err -> return (Left (ServerWriteFailed err))
        Right () -> return (Right ())

{- | The socket-backed response sink: chunks go out with 'sendAllWithin'; a file
body is sent zero-copy with 'sendfile' through 'socketSinkFile'.
-}
socketResponseSink :: Settings.Settings -> Socket.ClientSocket -> Http.ResponseSink
socketResponseSink settings client =
    Http.ResponseSink
        { Http.sinkChunk = socketChunkWriter settings client
        , Http.sinkFile = socketSinkFile settings client
        }

-- | The chunk writer: send bytes within the idle write timeout, mapping failure to a 'StreamError'.
socketChunkWriter :: Settings.Settings -> Socket.ClientSocket -> Http.ResponseWriter
socketChunkWriter settings client bytes = do
    sent <- Socket.sendAllWithin (Settings.settingsIdleWriteTimeoutMicros settings) client bytes
    case sent of
        Left err -> return (Left (Stream.StreamWriteError err))
        Right () -> return (Right ())

{- | Sends a file response zero-copy: open the file read-only, write the head
with the carried size as @Content-Length@, @sendfile@ the body, then close. The
size is the one resolved when the 'FileBody' was built, so no @lseek@ happens
here. An open failure -- a rare time-of-check/time-of-use race after
'MicroHttp.Static.serveStatic' already found the file -- aborts the connection,
like a streamed body that fails mid-flight.
-}
socketSinkFile :: Settings.Settings -> Socket.ClientSocket -> Http.Response -> FilePath -> Int -> IO (Either Stream.StreamError ())
socketSinkFile settings client response path size = do
    opened <- Socket.openFileRead path
    case opened of
        Nothing -> return (Left (Stream.StreamSourceError ("cannot open file: " ++ path)))
        Just fd -> do
            result <- sendHeadThenFile settings client response fd size
            Socket.closeFileFd fd
            return result

-- | Write the file's response head, then @sendfile@ its body within the idle write timeout.
sendHeadThenFile :: Settings.Settings -> Socket.ClientSocket -> Http.Response -> Socket.FileFd -> Int -> IO (Either Stream.StreamError ())
sendHeadThenFile settings client response fd size = do
    sentHead <- socketChunkWriter settings client (Http.serialiseFileHead response size)
    case sentHead of
        Left err -> return (Left err)
        Right () -> do
            sentBody <- Socket.sendFileWithin (Settings.settingsIdleWriteTimeoutMicros settings) client fd 0 size
            case sentBody of
                Left err -> return (Left (Stream.StreamWriteError err))
                Right () -> return (Right ())

-- | Map a 'StreamError' to a 'ServerError', distinguishing read failures from other stream failures.
streamFailure :: Stream.StreamError -> ServerError
streamFailure err =
    case err of
        Stream.StreamReadError socketError -> ServerReadFailed socketError
        _ -> ServerStreamFailed err
