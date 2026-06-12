{- | The server's access-log vocabulary. The log lives at the connection
layer (RFC-0009): every accepted connection yields a terminal event, and a
'RequestReceived' is emitted once the head parses. The 'Logger' sink and the
line format are injected, so the destination and the format are swappable;
'formatLogfmt' is the default logfmt format and 'logfmtTo' builds a logger
from a line sink. This module depends only on 'MicroHttp.Http', so the abort
reason is a plain label rather than the server's 'ServerError', which keeps
the server free to depend on this module without a cycle.
-}
module MicroHttp.Log (
    AccessEvent (..),
    Logger,
    nullLogger,
    formatLogfmt,
    logfmtTo,
    fileLogfmtLogger,
) where

import Data.List (intercalate)
import MicroHttp.Http (RequestHead (..), Status (..))
import System.IO (appendFile)

-- | An injected access-log sink.
type Logger = AccessEvent -> IO ()

{- | A logged moment in a connection's life. 'RequestReceived' carries the
parsed head; 'RequestCompleted' carries the written response's status, the
bytes written, and the duration in milliseconds (the head is 'Nothing' when
the request did not parse, as for a 400 or a 408 during the header read);
'RequestAborted' carries a short error label and the duration when the
connection failed without a clean response.
-}
data AccessEvent
    = RequestReceived RequestHead
    | RequestCompleted (Maybe RequestHead) Status Int Int
    | RequestAborted (Maybe RequestHead) String Int

-- | The no-op logger: logging disabled.
nullLogger :: Logger
nullLogger _ = pure ()

-- | Builds a logger that formats each event as logfmt and writes the line.
logfmtTo :: (String -> IO ()) -> Logger
logfmtTo emit event = emit (formatLogfmt event)

{- | A logfmt logger that appends each line to a file at the given path. It
opens the file in append mode for each line, so writes go to the end without a
shared handle; this is adequate for low to moderate request volume. A shared
handle or buffered sink can replace it if volume warrants.
-}
fileLogfmtLogger :: FilePath -> Logger
fileLogfmtLogger path = logfmtTo (\line -> appendFile path (line ++ "\n"))

-- | Renders an access event as a single logfmt line.
formatLogfmt :: AccessEvent -> String
formatLogfmt event =
    case event of
        RequestReceived head ->
            "event=RQST"
                ++ " method="
                ++ methodField (Just head)
                ++ " path="
                ++ pathField (Just head)
        RequestCompleted head status bytes durationMillis ->
            "event=RESP"
                ++ " method="
                ++ methodField head
                ++ " path="
                ++ pathField head
                ++ " status="
                ++ show (statusCode status)
                ++ " bytes="
                ++ show bytes
                ++ " dur_ms="
                ++ show durationMillis
        RequestAborted head reason durationMillis ->
            "event=ABRT"
                ++ " method="
                ++ methodField head
                ++ " path="
                ++ pathField head
                ++ " error="
                ++ reason
                ++ " dur_ms="
                ++ show durationMillis

methodField :: Maybe RequestHead -> String
methodField Nothing = "-"
methodField (Just head) = show (requestMethod head)

pathField :: Maybe RequestHead -> String
pathField Nothing = "-"
pathField (Just head) = renderPath (requestPath head)

renderPath :: [String] -> String
renderPath segments = "/" ++ intercalate "/" segments
