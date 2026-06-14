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

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http (Response (..), ResponseBody (..), Status (..), normaliseHeaderName)
import MicroHttp.Http.Response (serialiseHead, serialiseResponse)
import MicroHttp.Iteratee (Enumerator, Iter (..), Stream (..))
import MicroHttp.Log (AccessEvent (..), Logger, RequestLine (..))
import MicroHttp.Network.Socket (ConnectionInfo)
import MicroHttp.Stream (StreamError (..))
import System.IO.TimeMilli (getTimeMilli)

{- | An application consumes the raw request stream for a connection and yields
a response. The 'ConnectionInfo' carries non-payload metadata (the peer).
-}
type Application = ConnectionInfo -> Iter StreamError Response

-- | A middleware wraps an application.
type Middleware = Application -> Application

{- | Head-level middleware: transform the response value, no streams. For
example, adding a header or rewriting the status.
-}
mapResponse :: (Response -> Response) -> Middleware
mapResponse f app conn = fmap f (app conn)

{- | Ingress middleware: lift an enumeratee around the request consumption,
for example bounding the bytes the application reads.
-}
ingress :: (Iter StreamError Response -> Iter StreamError Response) -> Middleware
ingress stage app conn = stage (app conn)

{- | Egress middleware: fuse an enumeratee onto a streaming response body so it
runs before the sink. A strict body is left unchanged.
-}
egress :: (Iter StreamError () -> Iter StreamError ()) -> Middleware
egress stage app conn = fmap (fuseBody stage) (app conn)

fuseBody :: (Iter StreamError () -> Iter StreamError ()) -> Response -> Response
fuseBody stage response =
    case responseBody response of
        StrictBody _ -> response
        StreamBody enumerator -> response{responseBody = StreamBody (fuse enumerator)}
  where
    fuse :: Enumerator StreamError () -> Enumerator StreamError ()
    fuse enumerator sink = enumerator (stage sink)

{- | Failure-handling middleware: intercept a terminal failure and answer with
a replacement response instead. Successful results pass through.
-}
catchIter :: (StreamError -> Response) -> Middleware
catchIter handler app conn = recover (app conn)
  where
    recover it = case it of
        Done a residue -> Done a residue
        NeedInput k -> NeedInput (recover . k)
        IterM m -> IterM (fmap recover m)
        IterFailed err _ -> pure (handler err)

{- | Maps the framing/parse failures to default error responses: a parse or
limit failure to 400, an idle-read timeout to 408. A transport read failure is
left as a terminal failure, so the connection closes with no response.
-}
withErrorResponses :: Middleware
withErrorResponses app conn = recover (app conn)
  where
    recover it = case it of
        Done a residue -> Done a residue
        NeedInput k -> NeedInput (recover . k)
        IterM m -> IterM (fmap recover m)
        IterFailed err residue ->
            case errorResponseFor err of
                Just response -> Done response residue
                Nothing -> IterFailed err residue

errorResponseFor :: StreamError -> Maybe Response
errorResponseFor err =
    case err of
        StreamParseError _ -> Just badRequestResponse
        StreamTimeout -> Just requestTimeoutResponse
        _ -> Nothing

{- | The outermost middleware: it taps the request's first line (method and
target) to log a received event with the peer the moment it arrives, counts the
request bytes, and on the terminal step logs a completed or aborted event. The
response size is exact: a strict body's serialised length is known at the Done
step, and a streaming body is counted through an egress stage that logs the
completed event when the body finishes (its head length plus the body bytes).
-}
logRequests :: Logger -> Middleware
logRequests logger inner conn = IterM start
  where
    start = do
        startMillis <- getTimeMilli
        return (tap startMillis (Buffering B.empty) 0 (inner conn))

    tap startMillis lineState reqBytes it =
        case it of
            NeedInput k -> NeedInput (consume startMillis lineState reqBytes k)
            IterM m -> IterM (fmap (tap startMillis lineState reqBytes) m)
            Done response residue -> completed startMillis lineState reqBytes response residue
            IterFailed err residue ->
                IterM (logAborted startMillis lineState reqBytes err >> return (IterFailed err residue))

    consume startMillis lineState reqBytes k stream =
        case stream of
            Chunk bytes ->
                let reqBytes' = reqBytes + B.length bytes
                    (lineState', received) = advanceLine lineState bytes
                    next = tap startMillis lineState' reqBytes' (k (Chunk bytes))
                 in case received of
                        Just line -> IterM (logger (RequestReceived conn line) >> return next)
                        Nothing -> next
            EndOfStream merr -> tap startMillis lineState reqBytes (k (EndOfStream merr))

    -- A strict body's size is known now; a streaming body is counted as the
    -- server writes it, logging the completed event at the body's end.
    completed startMillis lineState reqBytes response residue =
        case responseBody response of
            StrictBody _ ->
                IterM
                    ( logCompleted startMillis lineState reqBytes (responseStatus response) (strictResponseSize response)
                        >> return (Done response residue)
                    )
            StreamBody enumerator ->
                let headLength = B.length (serialiseHead response)
                    counted = countingBody startMillis lineState reqBytes (responseStatus response) headLength enumerator
                 in Done response{responseBody = StreamBody counted} residue

    logCompleted startMillis lineState reqBytes status respBytes = do
        endMillis <- getTimeMilli
        logger (RequestCompleted conn (lineOf lineState) status reqBytes respBytes (endMillis - startMillis))

    logAborted startMillis lineState reqBytes err = do
        endMillis <- getTimeMilli
        logger (RequestAborted conn (lineOf lineState) (streamErrorLabel err) reqBytes (endMillis - startMillis))

    -- \| Wraps a streaming response body so the bytes are tallied as they reach
    --    the sink and the completed event is logged (head length plus body bytes)
    --    when the stream ends.
    --
    countingBody startMillis lineState reqBytes status headLength enumerator sink =
        enumerator (countStage 0 sink)
      where
        countStage tally inner' =
            case inner' of
                NeedInput k -> NeedInput (countConsume tally k)
                IterM m -> IterM (fmap (countStage tally) m)
                other -> other
        countConsume tally k stream =
            case stream of
                Chunk bytes -> countStage (tally + B.length bytes) (k (Chunk bytes))
                EndOfStream merr ->
                    IterM
                        ( logCompleted startMillis lineState reqBytes status (headLength + tally)
                            >> return (k (EndOfStream merr))
                        )

strictResponseSize :: Response -> Int
strictResponseSize response =
    case serialiseResponse response of
        Right bytes -> B.length bytes
        Left _ -> 0

{- | The first-line tap state: still buffering bytes until the first CRLF, or
the parsed request line.
-}
data LineState
    = Buffering B.ByteString
    | Seen RequestLine

advanceLine :: LineState -> B.ByteString -> (LineState, Maybe RequestLine)
advanceLine (Seen line) _ = (Seen line, Nothing)
advanceLine (Buffering buffered) bytes =
    case breakCrlf (B.append buffered bytes) of
        Nothing -> (Buffering (B.append buffered bytes), Nothing)
        Just lineBytes ->
            let line = parseRequestLine lineBytes
             in (Seen line, Just line)

lineOf :: LineState -> Maybe RequestLine
lineOf (Buffering _) = Nothing
lineOf (Seen line) = Just line

breakCrlf :: B.ByteString -> Maybe B.ByteString
breakCrlf bytes =
    case B.breakSubstring (BS.pack "\r\n") bytes of
        (before, after)
            | B.null after -> Nothing
            | otherwise -> Just before

parseRequestLine :: B.ByteString -> RequestLine
parseRequestLine lineBytes =
    case BS.words lineBytes of
        (method : target : _) -> RequestLine (BS.unpack method) (BS.unpack target)
        [method] -> RequestLine (BS.unpack method) ""
        [] -> RequestLine "" ""

streamErrorLabel :: StreamError -> String
streamErrorLabel err =
    case err of
        StreamReadError _ -> "StreamReadError"
        StreamWriteError _ -> "StreamWriteError"
        StreamParseError _ -> "StreamParseError"
        StreamSourceError _ -> "StreamSourceError"
        StreamTimeout -> "StreamTimeout"

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
