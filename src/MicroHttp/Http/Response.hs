module MicroHttp.Http.Response
  ( ResponseSerialiseError(..)
  , serialiseResponse
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import MicroHttp.Http

data ResponseSerialiseError
  = CannotSerialiseFileBody
  deriving (Eq, Show)

serialiseResponse :: Response -> Either ResponseSerialiseError BS.ByteString
serialiseResponse response =
  case responseBody response of
    StrictBody body ->
      Right (BS.concat
        [ statusLine (responseStatus response)
        , responseHeadersBytes (responseHeaders response)
        , BSC.pack "Content-Length: "
        , BSC.pack (show (BS.length body))
        , BSC.pack "\r\nConnection: close\r\n\r\n"
        , body
        ])
    FileBody _ ->
      Left CannotSerialiseFileBody

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
