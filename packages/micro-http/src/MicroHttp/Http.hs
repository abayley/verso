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
    serialiseSizedHead,
    writeResponse,
    mapBody,
    BlockTransform (..),
    transformedFileResponse,
    transformedTempFileResponse,
    transformedBytesResponse,
) where

import qualified Control.Exception as Exception
import qualified Control.Monad as Monad
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Char as Char
import qualified MicroHttp.FileSystem as FileSystem
import MicroHttp.Http.Parse (ParseError (..), ParseLimits (..), defaultParseLimits)
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Percent as Percent
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8

{- | An application consumes the raw request stream for a connection and yields
a response (RFC-0012). The 'ConnectionInfo' carries the connection's non-payload
metadata (the peer). The contract lives here, in the core types module, so that
naming it does not drag in the middleware machinery; the middleware combinators
and the 'MicroHttp.Middleware.Middleware' alias build on it.
-}
type Application = Socket.ConnectionInfo -> Iteratee.Iter Stream.StreamError Response

-- | An HTTP request method.
data Method
    = GET
    | POST
    | PUT
    | PATCH
    | DELETE
    | HEAD
    | OPTIONS
    deriving (Eq, Show)

-- | Parses a method token into a 'Method', or 'Nothing' if unrecognised.
parseMethod :: BS.ByteString -> Maybe Method
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

-- | A header field name, normalised to lower case.
newtype HeaderName = HeaderName BS.ByteString
    deriving (Eq, Show)

-- | A single header field: its name paired with its raw value bytes.
type Header = (HeaderName, BS.ByteString)

-- | A list of header fields.
type Headers = [Header]

-- | The raw request-target path bytes, before percent-decoding.
type RawPath = BS.ByteString

{- | The parsed head of a request: everything before the body. The body is
consumed downstream as a stream, so it is not a field here.
-}
data RequestHead = RequestHead
    { requestMethod :: Method
    , requestPath :: [String]
    , requestQuery :: [(String, String)]
    , requestHeaders :: Headers
    , requestRawPath :: RawPath
    , requestPeer :: Socket.ConnectionInfo
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
        , requestPeer = Socket.ConnectionInfo Socket.HostAny (Socket.Port 0)
        }

-- | An HTTP response: a status, header fields, and a body.
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
    = StrictBody BS.ByteString
    | StreamBody (Iteratee.Enumerator Stream.StreamError ())
    | {- | A streaming body whose total length is known before the first byte is
      written, so the head carries an exact @Content-Length@ (RFC-0040). The
      enumerator produces the body a segment at a time; the length is the sum
      of those segments' bytes, resolved once where the body is built.
      -}
      SizedStreamBody Int (Iteratee.Enumerator Stream.StreamError ())
    | FileBody FilePath Int

{- | Equality compares strict bodies, and file paths with sizes; a streaming
body (sized or close-delimited) is never equal, because it carries an opaque
producer.
-}
instance Eq ResponseBody where
    StrictBody a == StrictBody b = a == b
    FileBody pathA sizeA == FileBody pathB sizeB = pathA == pathB && sizeA == sizeB
    _ == _ = False

instance Show ResponseBody where
    show (StrictBody body) = "StrictBody " ++ show body
    show (StreamBody _) = "StreamBody <stream>"
    show (SizedStreamBody size _) = "SizedStreamBody " ++ show size ++ " <stream>"
    show (FileBody path size) = "FileBody " ++ show path ++ " " ++ show size

-- | An HTTP response status: a numeric code and its reason phrase.
data Status = Status
    { statusCode :: Int
    , statusReason :: String
    }
    deriving (Eq, Show)

-- | The @200 OK@ status.
okStatus :: Status
okStatus = Status 200 "OK"

-- | Normalises a header name to a lower-cased 'HeaderName' for comparison.
normaliseHeaderName :: BS.ByteString -> HeaderName
normaliseHeaderName name =
    HeaderName (BSC.pack (map lowerAscii (BSC.unpack name)))

-- | Recovers the raw bytes of a 'HeaderName'.
renderHeaderName :: HeaderName -> BS.ByteString
renderHeaderName (HeaderName name) = name

-- | Lower-cases an ASCII upper-case letter, leaving other characters as-is.
lowerAscii :: Char -> Char
lowerAscii c
    | Char.isAsciiUpper c = toEnum (fromEnum c + 32)
    | otherwise = c

-- | Percent-decodes a path segment; a literal @+@ is kept.
decodePathSegment :: String -> String
decodePathSegment = decode False

-- | Percent-decodes a form value; a literal @+@ becomes a space.
decodeFormValue :: String -> String
decodeFormValue = decode True

{- | Percent-decodes a string; when the flag is set, a literal @+@ becomes a
space. The decoding itself is 'Percent.decodeWhole' (RFC-0042 and the WHATWG
recovery rule for a malformed escape).

The @String@ here carries bytes, not characters: it comes from @Char8.unpack@ of
the request line, so every character is a byte and @Char8.pack@ is its exact
inverse. A character above @U+00FF@ is outside that contract and does not survive.
-}
decode :: Bool -> String -> String
decode plusIsSpace = BSC.unpack . Percent.decodeWhole plusIsSpace . BSC.pack

{- | Parses a framed header block (the bytes before the CRLFCRLF terminator,
which the framing iteratee has already located) into a 'RequestHead'. The
body is no longer the parser's concern: it is consumed downstream as a
stream. Header and body size limits are enforced by framing and the body
cap stage, not here.
-}
parseRequestHead :: BS.ByteString -> Either Parse.ParseError RequestHead
parseRequestHead input =
    case splitLines (BSC.unpack input) of
        [] -> Left (Parse.BadRequest "empty request")
        requestLine : headerLines ->
            case words requestLine of
                [methodToken, target, version] ->
                    case parseMethod (BSC.pack methodToken) of
                        Nothing -> Left (Parse.UnsupportedMethod (BSC.pack methodToken))
                        Just method ->
                            if version /= "HTTP/1.1" && version /= "HTTP/1.0"
                                then Left Parse.UnsupportedHttpVersion
                                else parseHeaders method target headerLines
                _ -> Left (Parse.BadRequest "invalid request line")

{- | Parses the header lines (after the request line) into a 'RequestHead',
rejecting non-identity transfer encodings.
-}
parseHeaders :: Method -> String -> [String] -> Either Parse.ParseError RequestHead
parseHeaders method target headerLines =
    case traverse parseHeader headerLines of
        Left err -> Left err
        Right headers ->
            case lookupHeader "transfer-encoding" headers of
                Just value
                    | BSC.unpack (lowerBytes value) /= "identity" ->
                        Left Parse.UnsupportedTransferEncoding
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

-- | Parses one @Name: value@ header line into a normalised 'Header'.
parseHeader :: String -> Either Parse.ParseError Header
parseHeader line =
    case break (== ':') line of
        (name, ':' : value) ->
            Right (normaliseHeaderName (BSC.pack (trim name)), BSC.pack (trim value))
        _ -> Left (Parse.BadRequest ("invalid header: " ++ line))

-- | Looks up a header by (un-normalised) name, comparing normalised names.
lookupHeader :: String -> Headers -> Maybe BS.ByteString
lookupHeader _ [] = Nothing
lookupHeader name ((key, value) : rest)
    | normaliseHeaderName (BSC.pack name) == key = Just value
    | otherwise = lookupHeader name rest

-- | Splits a request target into its path and query (without the @?@).
splitTarget :: String -> (String, String)
splitTarget target =
    case break (== '?') target of
        (pathText, '?' : queryText) -> (pathText, queryText)
        (pathText, _) -> (pathText, "")

{- | Splits a path into its non-empty segments, each percent-decoded and then
decoded from UTF-8 (RFC-0043): the request target is ASCII on the wire, and the
bytes a percent-escape stands for are UTF-8 (RFC 3986 section 2.5, the WHATWG URL
standard), so a segment reaching a handler is real characters.
-}
pathSegments :: String -> [String]
pathSegments pathText =
    map (Utf8.decodeUtf8 . decodePathSegment) (filter (/= "") (splitOn '/' pathText))

-- | Parses a query string into key-value pairs, percent-decoded and then decoded from UTF-8 (as 'pathSegments').
parseQuery :: String -> [(String, String)]
parseQuery "" = []
parseQuery queryText = map parsePair (splitOn '&' queryText)
  where
    parsePair text =
        case break (== '=') text of
            (key, '=' : value) -> (decodeText key, decodeText value)
            (key, _) -> (decodeText key, "")
    decodeText = Utf8.decodeUtf8 . decodeFormValue

-- | Splits text on CRLF line boundaries.
splitLines :: String -> [String]
splitLines = splitOnString "\r\n"

-- | Splits text on a single-character separator, keeping empty fields.
splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

-- | Splits text on a multi-character separator string.
splitOnString :: String -> String -> [String]
splitOnString separator text =
    case breakOn separator text of
        Just (before, after) ->
            before : splitOnString separator (drop (length separator) after)
        Nothing -> [text]

{- | Finds the first occurrence of a needle, returning the text before it and
the remainder (including the needle), or 'Nothing' if absent.
-}
breakOn :: String -> String -> Maybe (String, String)
breakOn needle = go ""
  where
    go _ [] = Nothing
    go prefix rest
        | needle `isPrefixOfLocal` rest = Just (reverse prefix, rest)
        | otherwise = go (head rest : prefix) (tail rest)

-- | Whether the first string is a prefix of the second.
isPrefixOfLocal :: String -> String -> Bool
isPrefixOfLocal [] _ = True
isPrefixOfLocal _ [] = False
isPrefixOfLocal (x : xs) (y : ys) = x == y && isPrefixOfLocal xs ys

-- | Strips leading and trailing whitespace.
trim :: String -> String
trim = reverse . dropWhile Char.isSpace . reverse . dropWhile Char.isSpace

-- | Lower-cases the ASCII letters in a byte string.
lowerBytes :: BS.ByteString -> BS.ByteString
lowerBytes value =
    BSC.pack (map lowerAscii (BSC.unpack value))

{- | Frames request headers as an iteratee: it accumulates input until the
CRLFCRLF terminator, enforcing 'maxHeaderBytes' incrementally. The result
is the header bytes before the terminator; the residue is the body prefix,
threaded onward by bind. End of stream before the terminator is an
incomplete request.
-}
frameHeadersI :: Parse.ParseLimits -> Iteratee.Iter Stream.StreamError BS.ByteString
frameHeadersI limits = go BS.empty
  where
    go buffered = Iteratee.NeedInput (consume buffered)
    consume buffered s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go buffered
            | otherwise -> scan (BS.append buffered bytes)
        Iteratee.EndOfStream Nothing ->
            Iteratee.IterFailed (Stream.StreamParseError (Parse.BadRequest "incomplete request")) (Iteratee.EndOfStream Nothing)
        Iteratee.EndOfStream (Just err) ->
            Iteratee.IterFailed err (Iteratee.EndOfStream (Just err))

    scan buffered =
        case BS.breakSubstring headerTerminator buffered of
            (before, after)
                | BS.null after ->
                    if BS.length buffered > Parse.maxHeaderBytes limits + terminatorLength
                        then Iteratee.IterFailed (Stream.StreamParseError Parse.HeaderTooLarge) (Iteratee.Chunk buffered)
                        else go buffered
                | otherwise ->
                    Iteratee.Done before (Iteratee.Chunk (BS.drop terminatorLength after))

headerTerminator :: BS.ByteString
headerTerminator = BSC.pack "\r\n\r\n"

terminatorLength :: Int
terminatorLength = 4

-- | Why a response could not be serialised to bytes.
data ResponseSerialiseError
    = CannotSerialiseStreamBody
    deriving (Eq, Show)

-- | Writes one response chunk, reporting a stream failure on write error.
type ResponseWriter = BS.ByteString -> IO (Either Stream.StreamError ())

{- | The response writer's sink (RFC-0014). A 'StrictBody' or 'StreamBody' is
written chunk-by-chunk through 'sinkChunk' (head and bytes alike); a 'FileBody'
is delegated whole to 'sinkFile' with its path. The sink sizes the file itself
from what it opens, so the head's @Content-Length@ and the bytes sent agree
whatever happened to the path since the handler resolved it; the size a
'FileBody' carries serves only the access log, which may therefore be stale
(RFC-0042 review). The socket sink sends a file via @sendfile(2)@; the in-memory
test sink reads the file and replays it through 'sinkChunk'.
-}
data ResponseSink = ResponseSink
    { sinkChunk :: ResponseWriter
    , sinkFile :: Response -> FilePath -> IO (Either Stream.StreamError ())
    }

{- | Serialises a response to bytes for the strict-body case, with a computed
@Content-Length@. A streaming or file body has no pure serialisation; it is
written incrementally by 'writeResponse' (a file body is sized by the sink).
-}
serialiseResponse :: Response -> Either ResponseSerialiseError BS.ByteString
serialiseResponse response =
    case responseBody response of
        StrictBody body -> Right (serialiseStrict response body)
        StreamBody _ -> Left CannotSerialiseStreamBody
        SizedStreamBody _ _ -> Left CannotSerialiseStreamBody
        FileBody _ _ -> Left CannotSerialiseStreamBody

{- | Writes a response through a 'ResponseSink': a strict body goes out as one
serialised chunk with @Content-Length@; a close-delimited streaming body writes
a head with no length then drives the body enumerator into the chunk writer; a
sized streaming body writes a head with an exact @Content-Length@ then drives
its enumerator the same way (RFC-0040); a file body is handed whole to
'sinkFile', which sizes the file, writes the head with an exact @Content-Length@,
and sends the bytes.
-}
writeResponse :: ResponseSink -> Response -> IO (Either Stream.StreamError ())
writeResponse sink response =
    case responseBody response of
        StrictBody body -> sinkChunk sink (serialiseStrict response body)
        StreamBody enumerator -> do
            sent <- sinkChunk sink (serialiseHead response)
            case sent of
                Left err -> return (Left err)
                Right () -> enumerator (Iteratee.byteSinkI (sinkChunk sink)) >>= Iteratee.run
        SizedStreamBody size enumerator -> do
            sent <- sinkChunk sink (serialiseSizedHead response size)
            case sent of
                Left err -> return (Left err)
                Right () -> enumerator (Iteratee.byteSinkI (sinkChunk sink)) >>= Iteratee.run
        FileBody path _ -> sinkFile sink response path

{- | Transforms the enumerator of a streaming body (sized or close-delimited),
leaving a strict or file body unchanged (RFC-0049). The single place an egress
stage rewrites a body, so the body taxonomy is matched here, in the core module,
and not in the middleware. The @Content-Length@ of a 'SizedStreamBody' is kept, so
a stage that changes the byte count of a sized body is the caller's responsibility,
as it was before.
-}
mapBody :: (Iteratee.Enumerator Stream.StreamError () -> Iteratee.Enumerator Stream.StreamError ()) -> Response -> Response
mapBody f response =
    case responseBody response of
        StrictBody _ -> response
        FileBody _ _ -> response
        StreamBody enumerator -> response{responseBody = StreamBody (f enumerator)}
        SizedStreamBody size enumerator -> response{responseBody = SizedStreamBody size (f enumerator)}

{- | The per-block operation of a sized streamed body (RFC-0049): the block size, the
transform applied to each block of the file, and the byte length that transform
produces -- computed cheaply, without allocating the transformed bytes, so the
count pass that sizes the response stays constant-space. The caller supplies both,
and the contract is @btLength b == fmap BS.length (btApply b)@; the response's
@Content-Length@ is summed from @btLength@ and the body streams @btApply@.
-}
data BlockTransform = BlockTransform
    { btBlockSize :: Int
    , btApply :: BS.ByteString -> IO BS.ByteString
    , btLength :: BS.ByteString -> IO Int
    }

{- | Builds a sized streamed response (RFC-0049): the @prefix@ bytes, the file at
@path@ streamed block by block through the transform, then the @suffix@ bytes,
behind an exact @Content-Length@ summed from the prefix and suffix lengths and the
transform's per-block length (a first pass counts it without holding the file). A
'Left' is returned when the file cannot be read for the count (it vanished), so the
caller answers a 404; the head is never written for a 'Left'.
-}
transformedFileResponse :: Status -> Headers -> BS.ByteString -> BlockTransform -> FilePath -> BS.ByteString -> IO (Either Stream.StreamError Response)
transformedFileResponse = sizedFileResponse Stream.transformedFileBody (const (pure ()))

{- | As 'transformedFileResponse' for a temporary capture served once: the streaming
body removes the file when it finishes or the consumer stops, and a count failure
removes it before the 'Left'.
-}
transformedTempFileResponse :: Status -> Headers -> BS.ByteString -> BlockTransform -> FilePath -> BS.ByteString -> IO (Either Stream.StreamError Response)
transformedTempFileResponse = sizedFileResponse Stream.transformedTempFileBody (Monad.void . FileSystem.removeFilePath)

-- | Shared core of the two file constructors: count under a cleanup, then build the sized body from the given producer.
sizedFileResponse ::
    (Int -> BS.ByteString -> (BS.ByteString -> IO BS.ByteString) -> FilePath -> BS.ByteString -> Iteratee.Enumerator Stream.StreamError ()) ->
    (FilePath -> IO ()) ->
    Status ->
    Headers ->
    BS.ByteString ->
    BlockTransform ->
    FilePath ->
    BS.ByteString ->
    IO (Either Stream.StreamError Response)
sizedFileResponse producer onMissing status headers prefix transform path suffix = do
    -- the count runs before the body owns the file, so a throw here cleans up as a missing file would
    counted <- Exception.onException (Stream.foldFileBlocks (btBlockSize transform) addLength 0 path) (onMissing path)
    case counted of
        Left err -> onMissing path >> pure (Left err)
        Right contentLength ->
            let total = BS.length prefix + contentLength + BS.length suffix
                body = producer (btBlockSize transform) prefix (btApply transform) path suffix
             in pure (Right (Response status headers (SizedStreamBody total body)))
  where
    addLength n block = (n +) <$> btLength transform block

{- | Builds a sized streamed response from in-memory content (RFC-0049): the
document that is not a file (a new-page seed). The content is transformed once and
emitted with the prefix and suffix as a single sized segment; there is no file, so
no failure.
-}
transformedBytesResponse :: Status -> Headers -> BS.ByteString -> (BS.ByteString -> IO BS.ByteString) -> BS.ByteString -> BS.ByteString -> IO Response
transformedBytesResponse status headers prefix apply content suffix = do
    transformed <- apply content
    let body = BS.concat [prefix, transformed, suffix]
    pure (Response status headers (SizedStreamBody (BS.length body) (Iteratee.strictEnumerator body)))

{- | Serialises a response with a strict body: status line, headers, an exact
@Content-Length@, @Connection: close@, then the body bytes.
-}
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

{- | The response head for a body of known length: status line, headers, an
exact @Content-Length@ from @size@, then @Connection: close@. Used by a file
body (RFC-0014, the bytes following from @sendfile@) and by a sized streaming
body (RFC-0040, the bytes following from its enumerator). @Connection: close@
stays (keep-alive is a later RFC, though an exact length now makes such a
response eligible).
-}
serialiseSizedHead :: Response -> Int -> BS.ByteString
serialiseSizedHead response size =
    BS.concat
        [ statusLine (responseStatus response)
        , responseHeadersBytes (responseHeaders response)
        , BSC.pack "Content-Length: "
        , BSC.pack (show size)
        , BSC.pack "\r\nConnection: close\r\n\r\n"
        ]

-- | Renders the @HTTP/1.1 <code> <reason>@ status line, CRLF-terminated.
statusLine :: Status -> BS.ByteString
statusLine status =
    BSC.pack
        ( "HTTP/1.1 "
            ++ show (statusCode status)
            ++ " "
            ++ statusReason status
            ++ "\r\n"
        )

-- | Renders a list of headers to their CRLF-terminated wire bytes.
responseHeadersBytes :: Headers -> BS.ByteString
responseHeadersBytes headers =
    BS.concat (map headerBytes headers)

-- | Renders a single header field to its CRLF-terminated wire bytes.
headerBytes :: Header -> BS.ByteString
headerBytes (name, value) =
    BS.concat
        [ renderHeaderName name
        , BSC.pack ": "
        , value
        , BSC.pack "\r\n"
        ]
