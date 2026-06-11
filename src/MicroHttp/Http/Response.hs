module MicroHttp.Http.Response (
    ResponseSerialiseError (..),
    ResponseWriter,
    serialiseResponse,
    serialiseHead,
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

{- | Serialises a response to bytes for the strict-body case, with a computed
@Content-Length@. A streaming body has no pure serialisation; it is written
incrementally by 'writeResponse'.
-}
serialiseResponse :: Response -> Either ResponseSerialiseError BS.ByteString
serialiseResponse response =
    case responseBody response of
        StrictBody body -> Right (serialiseStrict response body)
        StreamBody _ -> Left CannotSerialiseStreamBody

{- | Writes a response through a chunk writer: a strict body goes out as one
serialised chunk with @Content-Length@; a streaming body writes a
close-delimited head, then drives the body enumerator into the writer.
-}
writeResponse :: ResponseWriter -> Response -> IO (Either StreamError ())
writeResponse writer response =
    case responseBody response of
        StrictBody body -> writer (serialiseStrict response body)
        StreamBody enumerator -> do
            sent <- writer (serialiseHead response)
            case sent of
                Left err -> return (Left err)
                Right () -> enumerator (byteSinkI writer) >>= run

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
