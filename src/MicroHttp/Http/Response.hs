module MicroHttp.Http.Response (
    ResponseSerialiseError (..),
    ResponseWriter,
    ResponseSink (..),
    serialiseResponse,
    serialiseHead,
    serialiseFileHead,
    writeResponse,
) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import MicroHttp.Http
import MicroHttp.Iteratee (byteSinkI, run)
import MicroHttp.Stream (StreamError)

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
