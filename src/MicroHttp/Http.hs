module MicroHttp.Http (
    Method (..),
    HeaderName (..),
    Header,
    Headers,
    RawPath,
    RequestHead (..),
    Response (..),
    ResponseBody (..),
    Status (..),
    emptyRequestHead,
    okStatus,
    parseMethod,
    renderHeaderName,
    normaliseHeaderName,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Char (isAsciiUpper)
import MicroHttp.Iteratee (Enumerator)
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import MicroHttp.Stream (StreamError)

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
    case BS.unpack token of
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
    HeaderName (BS.pack (map lowerAscii (BS.unpack name)))

renderHeaderName :: HeaderName -> ByteString
renderHeaderName (HeaderName name) = name

lowerAscii :: Char -> Char
lowerAscii c
    | isAsciiUpper c = toEnum (fromEnum c + 32)
    | otherwise = c
