{- | The server's access-log vocabulary. Logging is a middleware
(RFC-0012): 'MicroHttp.Middleware.logRequests' taps the request stream for the
first line and observes the response, emitting these events. The 'Logger' sink
and the line format are injected, so the destination and format are swappable;
'formatLogfmt' is the default logfmt format and 'logfmtTo' / 'fileLogfmtLogger'
build loggers from a line sink.

An event carries the peer ('ConnectionInfo') and the request line as method and
target strings (what the logging middleware can cheaply tap from the first
line), not a fully parsed 'RequestHead'.
-}
module MicroHttp.Log (
    AccessEvent (..),
    RequestLine (..),
    Logger,
    nullLogger,
    formatLogfmt,
    logfmtTo,
    fileLogfmtLogger,
) where

import MicroHttp.Http (Status (..))
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import System.IO (appendFile)

-- | An injected access-log sink.
type Logger = AccessEvent -> IO ()

-- | The request's first line, as tapped: the method token and the target.
data RequestLine = RequestLine
    { requestLineMethod :: String
    , requestLineTarget :: String
    }

{- | A logged moment in a connection's life, carrying the peer. The request
line is 'Nothing' on the terminal event when no first line was seen (a peer
that connected and stalled). 'RequestCompleted' carries request bytes, response
bytes, and the duration in milliseconds; 'RequestAborted' carries request bytes
and the duration.
-}
data AccessEvent
    = RequestReceived ConnectionInfo RequestLine
    | RequestCompleted ConnectionInfo (Maybe RequestLine) Status Int Int Int
    | RequestAborted ConnectionInfo (Maybe RequestLine) String Int Int

-- | The no-op logger: logging disabled.
nullLogger :: Logger
nullLogger _ = pure ()

-- | Builds a logger that formats each event as logfmt and writes the line.
logfmtTo :: (String -> IO ()) -> Logger
logfmtTo emit event = emit (formatLogfmt event)

{- | A logfmt logger that appends each line to a file at the given path. It
opens the file in append mode for each line, so writes go to the end without a
shared handle; adequate for low to moderate request volume.
-}
fileLogfmtLogger :: FilePath -> Logger
fileLogfmtLogger path = logfmtTo (\line -> appendFile path (line ++ "\n"))

-- | Renders an access event as a single logfmt line.
formatLogfmt :: AccessEvent -> String
formatLogfmt event =
    case event of
        RequestReceived conn line ->
            "event=RQST" ++ peerField conn ++ lineFields (Just line)
        RequestCompleted conn line status reqBytes respBytes durationMillis ->
            "event=RESP"
                ++ peerField conn
                ++ lineFields line
                ++ " status="
                ++ show (statusCode status)
                ++ " req_bytes="
                ++ show reqBytes
                ++ " resp_bytes="
                ++ show respBytes
                ++ " dur_ms="
                ++ show durationMillis
        RequestAborted conn line reason reqBytes durationMillis ->
            "event=ABRT"
                ++ peerField conn
                ++ lineFields line
                ++ " error="
                ++ reason
                ++ " req_bytes="
                ++ show reqBytes
                ++ " dur_ms="
                ++ show durationMillis

peerField :: ConnectionInfo -> String
peerField conn = " peer=" ++ renderHost (connPeerHost conn)

renderHost :: Host -> String
renderHost HostAny = "0.0.0.0"
renderHost (HostIPv4 a b c d) =
    show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

lineFields :: Maybe RequestLine -> String
lineFields Nothing = " method=- path=-"
lineFields (Just line) =
    " method=" ++ requestLineMethod line ++ " path=" ++ requestLineTarget line
