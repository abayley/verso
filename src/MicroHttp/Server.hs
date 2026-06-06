module MicroHttp.Server (
    Application,
    ServerError (..),
    Settings (..),
    defaultSettings,
    respondToRequestBytes,
    serve,
    serveOne,
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.QSem
import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Http.Parser
import MicroHttp.Http.Response
import MicroHttp.Network.Socket

type Application = Request -> IO Response

data Settings = Settings
    { settingsHost :: Host
    , settingsPort :: Port
    , settingsBacklog :: Int
    , settingsMaxActiveHandlers :: Int
    , settingsMaxHeaderBytes :: Int
    , settingsMaxBodyBytes :: Int
    , settingsReadBufferBytes :: Int
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
        }

data ServerError
    = ServerListenFailed SocketError
    | ServerAcceptFailed SocketError
    | ServerReadFailed SocketError
    | ServerWriteFailed ResponseWriteError
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

respondToRequestBytes :: Settings -> Application -> BS.ByteString -> IO Response
respondToRequestBytes settings app bytes =
    case parseRequest (parseLimits settings) bytes of
        Left _ -> return badRequestResponse
        Right request -> app request

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
    received <- recv client (settingsReadBufferBytes settings)
    case received of
        Left err -> do
            _ <- closeClientSocket client
            return (Left (ServerReadFailed err))
        Right bytes -> do
            response <- respondToRequestBytes settings app bytes
            written <- writeResponse (sendChunk client) response
            _ <- closeClientSocket client
            case written of
                Left err -> return (Left (ServerWriteFailed err))
                Right () -> return (Right ())

sendChunk :: ClientSocket -> BS.ByteString -> IO (Either ResponseWriteError ())
sendChunk client chunk = do
    sent <- sendAll client chunk
    case sent of
        Left _ -> return (Left WriterFailed)
        Right () -> return (Right ())

parseLimits :: Settings -> ParseLimits
parseLimits settings =
    ParseLimits
        { maxHeaderBytes = settingsMaxHeaderBytes settings
        , maxBodyBytes = settingsMaxBodyBytes settings
        }

badRequestResponse :: Response
badRequestResponse =
    Response
        (Status 400 "Bad Request")
        [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (StrictBody (BS.pack "bad request\n"))
