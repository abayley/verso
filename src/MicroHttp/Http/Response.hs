module MicroHttp.Http.Response (
    ResponseSerialiseError (..),
    ResponseWriteError (..),
    ResponseWriter,
    serialiseResponse,
    writeResponse,
) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import MicroHttp.Http
import System.IO.Base (Handle, IOMode (..), hClose)
import System.IO.Open (openBinaryFileM)

data ResponseSerialiseError
    = CannotSerialiseFileBody
    deriving (Eq, Show)

data ResponseWriteError
    = CannotWriteSerialised ResponseSerialiseError
    | FileBodyOpenFailed FilePath
    | WriterFailed
    deriving (Eq, Show)

type ResponseWriter = BS.ByteString -> IO (Either ResponseWriteError ())

serialiseResponse :: Response -> Either ResponseSerialiseError BS.ByteString
serialiseResponse response =
    case responseBody response of
        StrictBody body ->
            Right
                ( BS.concat
                    [ statusLine (responseStatus response)
                    , responseHeadersBytes (responseHeaders response)
                    , BSC.pack "Content-Length: "
                    , BSC.pack (show (BS.length body))
                    , BSC.pack "\r\nConnection: close\r\n\r\n"
                    , body
                    ]
                )
        FileBody _ ->
            Left CannotSerialiseFileBody

writeResponse :: ResponseWriter -> Response -> IO (Either ResponseWriteError ())
writeResponse writer response =
    case responseBody response of
        StrictBody _ ->
            case serialiseResponse response of
                Left err -> return (Left (CannotWriteSerialised err))
                Right bytes -> writer bytes
        FileBody path -> writeFileResponse writer response path

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

writeFileResponse :: ResponseWriter -> Response -> FilePath -> IO (Either ResponseWriteError ())
writeFileResponse writer response path = do
    opened <- openBinaryFileM path ReadMode
    case opened of
        Nothing -> return (Left (FileBodyOpenFailed path))
        Just handle -> do
            headerWritten <- writer (fileHeaderBytes response)
            case headerWritten of
                Left err -> do
                    hClose handle
                    return (Left err)
                Right () -> writeFileChunks writer handle

fileHeaderBytes :: Response -> BS.ByteString
fileHeaderBytes response =
    BS.concat
        [ statusLine (responseStatus response)
        , responseHeadersBytes (responseHeaders response)
        , BSC.pack "Connection: close\r\n\r\n"
        ]

writeFileChunks :: ResponseWriter -> Handle -> IO (Either ResponseWriteError ())
writeFileChunks writer handle = do
    chunk <- BS.hGet handle 4096
    if BS.null chunk
        then do
            hClose handle
            return (Right ())
        else do
            written <- writer chunk
            case written of
                Left err -> do
                    hClose handle
                    return (Left err)
                Right () -> writeFileChunks writer handle
