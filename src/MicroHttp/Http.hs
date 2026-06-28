{- | The HTTP vocabulary and machinery: the core message types (methods,
headers, request head, response, status), request-head parsing, percent-decoding,
header framing, and response serialisation. These were previously split across
@MicroHttp.Http.{Parser,PercentEncoding,Framing,Response}@ and are now inlined
here so the framework presents a single HTTP module (RFC-0031).

The error and limit types ('ParseError', 'ParseLimits') still live in the small
internal module 'MicroHttp.Http.Parse' and are re-exported here: 'MicroHttp.Http'
uses 'StreamError' (from 'MicroHttp.Stream'), whose 'StreamError' wraps
'ParseError', so keeping the parse vocabulary in a leaf module is what avoids a
@Http@ <-> @Stream@ import cycle.
-}
module MicroHttp.Http (
    Method (..),
    HeaderName (..),
    Header,
    Headers,
    RawPath,
    Application,
    RequestHead (..),
    Response (..),
    ResponseBody (..),
    Status (..),
    emptyRequestHead,
    okStatus,
    parseMethod,
    renderHeaderName,
    normaliseHeaderName,
    ParseError (..),
    ParseLimits (..),
    defaultParseLimits,
    parseRequestHead,
    decodePathSegment,
    decodeFormValue,
    frameHeadersI,
    ResponseSerialiseError (..),
    ResponseWriter,
    ResponseSink (..),
    serialiseResponse,
    serialiseHead,
    serialiseFileHead,
    writeResponse,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isAsciiUpper, isDigit, isSpace)
import MicroHttp.Http.Parse (ParseError (..), ParseLimits (..), defaultParseLimits)
import MicroHttp.Iteratee (Enumerator, Iter (..), Stream (..), byteSinkI, run)
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import MicroHttp.Stream (StreamError (..))

{- | An application consumes the raw request stream for a connection and yields
a response (RFC-0012). The 'ConnectionInfo' carries the connection's non-payload
metadata (the peer). The contract lives here, in the core types module, so that
naming it does not drag in the middleware machinery; the middleware combinators
and the 'MicroHttp.Middleware.Middleware' alias build on it.
-}
type Application = ConnectionInfo -> Iter StreamError Response

data Method
    = GET
    | POST
    | PUT
    | PATCH
    | DELETE
    | HEAD
    | OPTIONS
    deriving (Eq, Show)

parseMethod :: ByteString -> Maybe Method
parseMethod token =
    case BSC.unpack token of
        "GET" -> Just GET
        "POST" -> Just POST
        "PUT" -> Just PUT
        "PATCH" -> Just PATCH
        "DELETE" -> Just DELETE
        "HEAD" -> Just HEAD
        "OPTIONS" -> Just OPTIONS
        _ -> Nothing

newtype HeaderName = HeaderName ByteString
    deriving (Eq, Show)

type Header = (HeaderName, ByteString)

type Headers = [Header]

type RawPath = ByteString

{- | The parsed head of a request: everything before the body. The body is
consumed downstream as a stream, so it is not a field here.
-}
data RequestHead = RequestHead
    { requestMethod :: Method
    , requestPath :: [String]
    , requestQuery :: [(String, String)]
    , requestHeaders :: Headers
    , requestRawPath :: RawPath
    , requestPeer :: ConnectionInfo
    }
    deriving (Eq, Show)

{- | A 'RequestHead' with empty payload and an unknown peer, for building heads
by record update. The parser fills the payload fields; the router fills
'requestPeer' from the connection. Routing construction through this default
keeps adding a field a one-line change here, not at every construction site.
-}
emptyRequestHead :: RequestHead
emptyRequestHead =
    RequestHead
        { requestMethod = GET
        , requestPath = []
        , requestQuery = []
        , requestHeaders = []
        , requestRawPath = BS.empty
        , requestPeer = ConnectionInfo HostAny (Port 0)
        }

data Response = Response
    { responseStatus :: Status
    , responseHeaders :: Headers
    , responseBody :: ResponseBody
    }

{- | A response body: a strict in-memory value, a streaming body produced by
an enumerator and written close-delimited, or a file sent zero-copy via
@sendfile(2)@ (RFC-0014). A 'FileBody' carries the file path and its size in
bytes, resolved once where the body is built; the size gives an exact
@Content-Length@ and is read by both the writer and the access log. The bytes
go kernel-to-kernel and bypass userspace, so an @egress@ stage cannot rewrite
them in place (it may replace the body to opt out of zero-copy); the portable
fallback remains @StreamBody (fileEnumerator path)@.
-}
data ResponseBody
    = StrictBody ByteString
    | StreamBody (Enumerator StreamError ())
    | FileBody FilePath Int

{- | Equality compares strict bodies, and file paths with sizes; a streaming
body is never equal, because it carries an opaque producer.
-}
instance Eq ResponseBody where
    StrictBody a == StrictBody b = a == b
    FileBody pathA sizeA == FileBody pathB sizeB = pathA == pathB && sizeA == sizeB
    _ == _ = False

instance Show ResponseBody where
    show (StrictBody body) = "StrictBody " ++ show body
    show (StreamBody _) = "StreamBody <stream>"
    show (FileBody path size) = "FileBody " ++ show path ++ " " ++ show size

data Status = Status
    { statusCode :: Int
    , statusReason :: String
    }
    deriving (Eq, Show)

okStatus :: Status
okStatus = Status 200 "OK"

normaliseHeaderName :: ByteString -> HeaderName
normaliseHeaderName name =
    HeaderName (BSC.pack (map lowerAscii (BSC.unpack name)))

renderHeaderName :: HeaderName -> ByteString
renderHeaderName (HeaderName name) = name

lowerAscii :: Char -> Char
lowerAscii c
    | isAsciiUpper c = toEnum (fromEnum c + 32)
    | otherwise = c

-- | Percent-decodes a path segment; a literal @+@ is kept.
decodePathSegment :: String -> String
decodePathSegment = decode False

-- | Percent-decodes a form value; a literal @+@ becomes a space.
decodeFormValue :: String -> String
decodeFormValue = decode True

decode :: Bool -> String -> String
decode _ [] = []
decode plusIsSpace ('%' : a : b : rest) =
    case hexPair a b of
        Just c -> c : decode plusIsSpace rest
        Nothing -> '%' : a : b : decode plusIsSpace rest
decode True ('+' : rest) = ' ' : decode True rest
decode plusIsSpace (c : rest) = c : decode plusIsSpace rest

hexPair :: Char -> Char -> Maybe Char
hexPair a b = (\high low -> toEnum (high * 16 + low)) <$> hexValue a <*> hexValue b

hexValue :: Char -> Maybe Int
hexValue c
    | isDigit c = Just (fromEnum c - fromEnum '0')
    | 'a' <= c && c <= 'f' = Just (10 + fromEnum c - fromEnum 'a')
    | 'A' <= c && c <= 'F' = Just (10 + fromEnum c - fromEnum 'A')
    | otherwise = Nothing

{- | Parses a framed header block (the bytes before the CRLFCRLF terminator,
which the framing iteratee has already located) into a 'RequestHead'. The
body is no longer the parser's concern: it is consumed downstream as a
stream. Header and body size limits are enforced by framing and the body
cap stage, not here.
-}
parseRequestHead :: BS.ByteString -> Either ParseError RequestHead
parseRequestHead input =
    case splitLines (BSC.unpack input) of
        [] -> Left (BadRequest "empty request")
        requestLine : headerLines ->
            case words requestLine of
                [methodToken, target, version] ->
                    case parseMethod (BSC.pack methodToken) of
                        Nothing -> Left (UnsupportedMethod (BSC.pack methodToken))
                        Just method ->
                            if version /= "HTTP/1.1" && version /= "HTTP/1.0"
                                then Left UnsupportedHttpVersion
                                else parseHeaders method target headerLines
                _ -> Left (BadRequest "invalid request line")

parseHeaders :: Method -> String -> [String] -> Either ParseError RequestHead
parseHeaders method target headerLines =
    case traverse parseHeader headerLines of
        Left err -> Left err
        Right headers ->
            case lookupHeader "transfer-encoding" headers of
                Just value
                    | BSC.unpack (lowerBytes value) /= "identity" ->
                        Left UnsupportedTransferEncoding
                _ ->
                    let (rawPath, queryText) = splitTarget target
                     in Right
                            emptyRequestHead
                                { requestMethod = method
                                , requestPath = pathSegments rawPath
                                , requestQuery = parseQuery queryText
                                , requestHeaders = headers
                                , requestRawPath = BSC.pack rawPath
                                }

parseHeader :: String -> Either ParseError Header
parseHeader line =
    case break (== ':') line of
        (name, ':' : value) ->
            Right (normaliseHeaderName (BSC.pack (trim name)), BSC.pack (trim value))
        _ -> Left (BadRequest ("invalid header: " ++ line))

lookupHeader :: String -> Headers -> Maybe BS.ByteString
lookupHeader _ [] = Nothing
lookupHeader name ((key, value) : rest)
    | normaliseHeaderName (BSC.pack name) == key = Just value
    | otherwise = lookupHeader name rest

splitTarget :: String -> (String, String)
splitTarget target =
    case break (== '?') target of
        (pathText, '?' : queryText) -> (pathText, queryText)
        (pathText, _) -> (pathText, "")

pathSegments :: String -> [String]
pathSegments pathText =
    map decodePathSegment (filter (/= "") (splitOn '/' pathText))

parseQuery :: String -> [(String, String)]
parseQuery "" = []
parseQuery queryText = map parsePair (splitOn '&' queryText)
  where
    parsePair text =
        case break (== '=') text of
            (key, '=' : value) -> (decodeFormValue key, decodeFormValue value)
            (key, _) -> (decodeFormValue key, "")

splitLines :: String -> [String]
splitLines = splitOnString "\r\n"

splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

splitOnString :: String -> String -> [String]
splitOnString separator text =
    case breakOn separator text of
        Just (before, after) ->
            before : splitOnString separator (drop (length separator) after)
        Nothing -> [text]

breakOn :: String -> String -> Maybe (String, String)
breakOn needle = go ""
  where
    go _ [] = Nothing
    go prefix rest
        | needle `isPrefixOfLocal` rest = Just (reverse prefix, rest)
        | otherwise = go (head rest : prefix) (tail rest)

isPrefixOfLocal :: String -> String -> Bool
isPrefixOfLocal [] _ = True
isPrefixOfLocal _ [] = False
isPrefixOfLocal (x : xs) (y : ys) = x == y && isPrefixOfLocal xs ys

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

lowerBytes :: BS.ByteString -> BS.ByteString
lowerBytes value =
    BSC.pack (map lowerAscii (BSC.unpack value))

{- | Frames request headers as an iteratee: it accumulates input until the
CRLFCRLF terminator, enforcing 'maxHeaderBytes' incrementally. The result
is the header bytes before the terminator; the residue is the body prefix,
threaded onward by bind. End of stream before the terminator is an
incomplete request.
-}
frameHeadersI :: ParseLimits -> Iter StreamError BS.ByteString
frameHeadersI limits = go BS.empty
  where
    go buffered = NeedInput (consume buffered)
    consume buffered s = case s of
        Chunk bytes
            | BS.null bytes -> go buffered
            | otherwise -> scan (BS.append buffered bytes)
        EndOfStream Nothing ->
            IterFailed (StreamParseError (BadRequest "incomplete request")) (EndOfStream Nothing)
        EndOfStream (Just err) ->
            IterFailed err (EndOfStream (Just err))

    scan buffered =
        case BS.breakSubstring headerTerminator buffered of
            (before, after)
                | BS.null after ->
                    if BS.length buffered > maxHeaderBytes limits + terminatorLength
                        then IterFailed (StreamParseError HeaderTooLarge) (Chunk buffered)
                        else go buffered
                | otherwise ->
                    Done before (Chunk (BS.drop terminatorLength after))

headerTerminator :: BS.ByteString
headerTerminator = BSC.pack "\r\n\r\n"

terminatorLength :: Int
terminatorLength = 4

data ResponseSerialiseError
    = CannotSerialiseStreamBody
    deriving (Eq, Show)

-- | Writes one response chunk, reporting a stream failure on write error.
type ResponseWriter = BS.ByteString -> IO (Either StreamError ())

{- | The response writer's sink (RFC-0014). A 'StrictBody' or 'StreamBody' is
written chunk-by-chunk through 'sinkChunk' (head and bytes alike); a 'FileBody'
is delegated whole to 'sinkFile' with its path and pre-resolved size. The socket
sink sends a file via @sendfile(2)@; the in-memory test sink reads the file and
replays it through 'sinkChunk'.
-}
data ResponseSink = ResponseSink
    { sinkChunk :: ResponseWriter
    , sinkFile :: Response -> FilePath -> Int -> IO (Either StreamError ())
    }

{- | Serialises a response to bytes for the strict-body case, with a computed
@Content-Length@. A streaming or file body has no pure serialisation; it is
written incrementally by 'writeResponse' (a file body needs the file size).
-}
serialiseResponse :: Response -> Either ResponseSerialiseError BS.ByteString
serialiseResponse response =
    case responseBody response of
        StrictBody body -> Right (serialiseStrict response body)
        StreamBody _ -> Left CannotSerialiseStreamBody
        FileBody _ _ -> Left CannotSerialiseStreamBody

{- | Writes a response through a 'ResponseSink': a strict body goes out as one
serialised chunk with @Content-Length@; a streaming body writes a
close-delimited head then drives the body enumerator into the chunk writer; a
file body is handed whole to 'sinkFile', which sizes the file, writes the head
with an exact @Content-Length@, and sends the bytes.
-}
writeResponse :: ResponseSink -> Response -> IO (Either StreamError ())
writeResponse sink response =
    case responseBody response of
        StrictBody body -> sinkChunk sink (serialiseStrict response body)
        StreamBody enumerator -> do
            sent <- sinkChunk sink (serialiseHead response)
            case sent of
                Left err -> return (Left err)
                Right () -> enumerator (byteSinkI (sinkChunk sink)) >>= run
        FileBody path size -> sinkFile sink response path size

serialiseStrict :: Response -> BS.ByteString -> BS.ByteString
serialiseStrict response body =
    BS.concat
        [ statusLine (responseStatus response)
        , responseHeadersBytes (responseHeaders response)
        , BSC.pack "Content-Length: "
        , BSC.pack (show (BS.length body))
        , BSC.pack "\r\nConnection: close\r\n\r\n"
        , body
        ]

{- | The response head for a close-delimited streaming body: status line,
headers, and @Connection: close@, with no @Content-Length@.
-}
serialiseHead :: Response -> BS.ByteString
serialiseHead response =
    BS.concat
        [ statusLine (responseStatus response)
        , responseHeadersBytes (responseHeaders response)
        , BSC.pack "Connection: close\r\n\r\n"
        ]

{- | The response head for a file body (RFC-0014): status line, headers, and an
exact @Content-Length@ from the file @size@, then @Connection: close@. The body
bytes follow from @sendfile@; @Connection: close@ stays (keep-alive is a later
RFC, though an exact length now makes a file response eligible).
-}
serialiseFileHead :: Response -> Int -> BS.ByteString
serialiseFileHead response size =
    BS.concat
        [ statusLine (responseStatus response)
        , responseHeadersBytes (responseHeaders response)
        , BSC.pack "Content-Length: "
        , BSC.pack (show size)
        , BSC.pack "\r\nConnection: close\r\n\r\n"
        ]

statusLine :: Status -> BS.ByteString
statusLine status =
    BSC.pack
        ( "HTTP/1.1 "
            ++ show (statusCode status)
            ++ " "
            ++ statusReason status
            ++ "\r\n"
        )

responseHeadersBytes :: Headers -> BS.ByteString
responseHeadersBytes headers =
    BS.concat (map headerBytes headers)

headerBytes :: Header -> BS.ByteString
headerBytes (name, value) =
    BS.concat
        [ renderHeaderName name
        , BSC.pack ": "
        , value
        , BSC.pack "\r\n"
        ]
