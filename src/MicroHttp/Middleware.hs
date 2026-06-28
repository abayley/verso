{- | The application contract and middleware (RFC-0012, ADR-015). An
'Application' consumes the raw request stream for one connection and yields a
'Response'; it receives the connection's non-payload metadata
('ConnectionInfo') as its argument. A 'Middleware' wraps an application; because
the application sits in the byte stream, a middleware can tap the request as it
flows down and observe the response as it flows back up.

The taxonomy:

  * 'mapResponse' transforms the response value;
  * 'ingress' lifts an enumeratee around the request consumption;
  * 'egress' fuses an enumeratee onto a streaming response body;
  * 'catchIter' replaces a terminal failure with a response;
  * 'withErrorResponses' maps a parse failure to 400 and an idle-read timeout
    to 408 (a read failure stays an abort);
  * 'logRequests' is the outermost middleware: it taps the first line, holds
    the connection peer, and emits the access-log events.
-}
module MicroHttp.Middleware (
    Application,
    Middleware,
    mapResponse,
    ingress,
    egress,
    catchIter,
    withErrorResponses,
    logRequests,
) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import MicroHttp.Http (Application)
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Stream as Stream
import qualified System.IO.TimeMilli as TimeMilli

{- | A middleware wraps an application. The 'Application' contract itself lives
in 'MicroHttp.Http' (re-exported here), so naming it needs no middleware deps.
-}
type Middleware = Http.Application -> Http.Application

{- | Head-level middleware: transform the response value, no streams. For
example, adding a header or rewriting the status.
-}
mapResponse :: (Http.Response -> Http.Response) -> Middleware
mapResponse f app conn = fmap f (app conn)

{- | Ingress middleware: lift an enumeratee around the request consumption,
for example bounding the bytes the application reads.
-}
ingress :: (Iteratee.Iter Stream.StreamError Http.Response -> Iteratee.Iter Stream.StreamError Http.Response) -> Middleware
ingress stage app conn = stage (app conn)

{- | Egress middleware: fuse an enumeratee onto a streaming response body so it
runs before the sink. A strict body is left unchanged.
-}
egress :: (Iteratee.Iter Stream.StreamError () -> Iteratee.Iter Stream.StreamError ()) -> Middleware
egress stage app conn = fmap (fuseBody stage) (app conn)

-- | Fuses an egress enumeratee onto a streaming body, leaving strict and file bodies untouched.
fuseBody :: (Iteratee.Iter Stream.StreamError () -> Iteratee.Iter Stream.StreamError ()) -> Http.Response -> Http.Response
fuseBody stage response =
    case Http.responseBody response of
        Http.StrictBody _ -> response
        Http.FileBody _ _ -> response
        Http.StreamBody enumerator -> response{Http.responseBody = Http.StreamBody (fuse enumerator)}
  where
    fuse :: Iteratee.Enumerator Stream.StreamError () -> Iteratee.Enumerator Stream.StreamError ()
    fuse enumerator sink = enumerator (stage sink)

{- | Failure-handling middleware: intercept a terminal failure and answer with
a replacement response instead. Successful results pass through.
-}
catchIter :: (Stream.StreamError -> Http.Response) -> Middleware
catchIter handler app conn = recover (app conn)
  where
    recover it = case it of
        Iteratee.Done a residue -> Iteratee.Done a residue
        Iteratee.NeedInput k -> Iteratee.NeedInput (recover . k)
        Iteratee.IterM m -> Iteratee.IterM (fmap recover m)
        Iteratee.IterFailed err _ -> pure (handler err)

{- | Maps the framing/parse failures to default error responses: a parse or
limit failure to 400, an idle-read timeout to 408. A transport read failure is
left as a terminal failure, so the connection closes with no response.
-}
withErrorResponses :: Middleware
withErrorResponses app conn = recover (app conn)
  where
    recover it = case it of
        Iteratee.Done a residue -> Iteratee.Done a residue
        Iteratee.NeedInput k -> Iteratee.NeedInput (recover . k)
        Iteratee.IterM m -> Iteratee.IterM (fmap recover m)
        Iteratee.IterFailed err residue ->
            case errorResponseFor err of
                Just response -> Iteratee.Done response residue
                Nothing -> Iteratee.IterFailed err residue

-- | Maps a stream framing failure to the default error response, if any.
errorResponseFor :: Stream.StreamError -> Maybe Http.Response
errorResponseFor err =
    case err of
        Stream.StreamParseError _ -> Just badRequestResponse
        Stream.StreamTimeout -> Just requestTimeoutResponse
        _ -> Nothing

{- | The outermost middleware: it taps the request's first line (method and
target) to log a received event with the peer the moment it arrives, counts the
request bytes, and on the terminal step logs a completed or aborted event. The
response size is exact: a strict body's serialised length is known at the Done
step, a file body carries its size (so head length plus that size is the wire
count, with no extra syscall), and a streaming body is counted through an egress
stage that logs the completed event when the body finishes (head length plus the
body bytes).
-}
logRequests :: Log.Logger -> Middleware
logRequests logger inner conn = Iteratee.IterM start
  where
    start = do
        startMillis <- TimeMilli.getTimeMilli
        return (tap startMillis (Buffering BS.empty) 0 (inner conn))

    tap startMillis lineState reqBytes it =
        case it of
            Iteratee.NeedInput k -> Iteratee.NeedInput (consume startMillis lineState reqBytes k)
            Iteratee.IterM m -> Iteratee.IterM (fmap (tap startMillis lineState reqBytes) m)
            Iteratee.Done response residue -> completed startMillis lineState reqBytes response residue
            Iteratee.IterFailed err residue ->
                Iteratee.IterM (logAborted startMillis lineState reqBytes err >> return (Iteratee.IterFailed err residue))

    consume startMillis lineState reqBytes k stream =
        case stream of
            Iteratee.Chunk bytes ->
                let reqBytes' = reqBytes + BS.length bytes
                    (lineState', received) = advanceLine lineState bytes
                    next = tap startMillis lineState' reqBytes' (k (Iteratee.Chunk bytes))
                 in case received of
                        Just line -> Iteratee.IterM (logger (Log.RequestReceived conn line) >> return next)
                        Nothing -> next
            Iteratee.EndOfStream merr -> tap startMillis lineState reqBytes (k (Iteratee.EndOfStream merr))

    -- A strict body's size is known now; a file body carries its size, so the
    -- head plus that size is the exact response byte count; a streaming body is
    -- counted as the server writes it, logging the completed event at its end.
    completed startMillis lineState reqBytes response residue =
        case Http.responseBody response of
            Http.StrictBody _ ->
                Iteratee.IterM
                    ( logCompleted startMillis lineState reqBytes (Http.responseStatus response) (strictResponseSize response)
                        >> return (Iteratee.Done response residue)
                    )
            Http.FileBody _ size ->
                Iteratee.IterM
                    ( logCompleted startMillis lineState reqBytes (Http.responseStatus response) (BS.length (Http.serialiseFileHead response size) + size)
                        >> return (Iteratee.Done response residue)
                    )
            Http.StreamBody enumerator ->
                let headLength = BS.length (Http.serialiseHead response)
                    counted = countingBody startMillis lineState reqBytes (Http.responseStatus response) headLength enumerator
                 in Iteratee.Done response{Http.responseBody = Http.StreamBody counted} residue

    logCompleted startMillis lineState reqBytes status respBytes = do
        endMillis <- TimeMilli.getTimeMilli
        logger (Log.RequestCompleted conn (lineOf lineState) status reqBytes respBytes (endMillis - startMillis))

    logAborted startMillis lineState reqBytes err = do
        endMillis <- TimeMilli.getTimeMilli
        logger (Log.RequestAborted conn (lineOf lineState) (streamErrorLabel err) reqBytes (endMillis - startMillis))

    -- \| Wraps a streaming response body so the bytes are tallied as they reach
    --    the sink and the completed event is logged (head length plus body bytes)
    --    when the stream ends.
    --
    countingBody startMillis lineState reqBytes status headLength enumerator sink =
        enumerator (countStage 0 sink)
      where
        countStage tally inner' =
            case inner' of
                Iteratee.NeedInput k -> Iteratee.NeedInput (countConsume tally k)
                Iteratee.IterM m -> Iteratee.IterM (fmap (countStage tally) m)
                other -> other
        countConsume tally k stream =
            case stream of
                Iteratee.Chunk bytes -> countStage (tally + BS.length bytes) (k (Iteratee.Chunk bytes))
                Iteratee.EndOfStream merr ->
                    Iteratee.IterM
                        ( logCompleted startMillis lineState reqBytes status (headLength + tally)
                            >> return (k (Iteratee.EndOfStream merr))
                        )

-- | The serialised wire length of a strict-body response (0 if serialisation fails).
strictResponseSize :: Http.Response -> Int
strictResponseSize response =
    case Http.serialiseResponse response of
        Right bytes -> BS.length bytes
        Left _ -> 0

{- | The first-line tap state: still buffering bytes until the first CRLF, or
the parsed request line.
-}
data LineState
    = Buffering BS.ByteString
    | Seen Log.RequestLine

-- | Feeds bytes into the first-line tap, parsing the request line once a CRLF is seen.
advanceLine :: LineState -> BS.ByteString -> (LineState, Maybe Log.RequestLine)
advanceLine (Seen line) _ = (Seen line, Nothing)
advanceLine (Buffering buffered) bytes =
    case breakCrlf (BS.append buffered bytes) of
        Nothing -> (Buffering (BS.append buffered bytes), Nothing)
        Just lineBytes ->
            let line = parseRequestLine lineBytes
             in (Seen line, Just line)

-- | The parsed request line held by the tap state, if one has been seen.
lineOf :: LineState -> Maybe Log.RequestLine
lineOf (Buffering _) = Nothing
lineOf (Seen line) = Just line

-- | Splits off the bytes before the first CRLF, or Nothing if no CRLF is present.
breakCrlf :: BS.ByteString -> Maybe BS.ByteString
breakCrlf bytes =
    case BS.breakSubstring (BSC.pack "\r\n") bytes of
        (before, after)
            | BS.null after -> Nothing
            | otherwise -> Just before

-- | Parses a request line's bytes into its method and target.
parseRequestLine :: BS.ByteString -> Log.RequestLine
parseRequestLine lineBytes =
    case BSC.words lineBytes of
        (method : target : _) -> Log.RequestLine (BSC.unpack method) (BSC.unpack target)
        [method] -> Log.RequestLine (BSC.unpack method) ""
        [] -> Log.RequestLine "" ""

-- | A short stable label naming the kind of a stream error, for the access log.
streamErrorLabel :: Stream.StreamError -> String
streamErrorLabel err =
    case err of
        Stream.StreamReadError _ -> "StreamReadError"
        Stream.StreamWriteError _ -> "StreamWriteError"
        Stream.StreamParseError _ -> "StreamParseError"
        Stream.StreamSourceError _ -> "StreamSourceError"
        Stream.StreamTimeout -> "StreamTimeout"

-- | The default 400 Bad Request response for parse and limit failures.
badRequestResponse :: Http.Response
badRequestResponse =
    Http.Response
        (Http.Status 400 "Bad Request")
        [(Http.normaliseHeaderName (BSC.pack "Content-Type"), BSC.pack "text/plain")]
        (Http.StrictBody (BSC.pack "bad request\n"))

-- | The default 408 Request Timeout response for an idle-read timeout.
requestTimeoutResponse :: Http.Response
requestTimeoutResponse =
    Http.Response
        (Http.Status 408 "Request Timeout")
        [(Http.normaliseHeaderName (BSC.pack "Content-Type"), BSC.pack "text/plain")]
        (Http.StrictBody (BSC.pack "request timeout\n"))
