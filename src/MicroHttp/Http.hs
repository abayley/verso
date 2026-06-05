module MicroHttp.Http
  ( Method(..)
  , HeaderName(..)
  , BodyBytes
  , Header
  , Headers
  , RawPath
  , Request(..)
  , Response(..)
  , ResponseBody(..)
  , Status(..)
  , okStatus
  , parseMethod
  , normaliseHeaderName
  ) where

import Data.ByteString(ByteString)
import qualified Data.ByteString.Char8 as BS

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
    "GET"     -> Just GET
    "POST"    -> Just POST
    "PUT"     -> Just PUT
    "PATCH"   -> Just PATCH
    "DELETE"  -> Just DELETE
    "HEAD"    -> Just HEAD
    "OPTIONS" -> Just OPTIONS
    _         -> Nothing

newtype HeaderName = HeaderName ByteString
  deriving (Eq, Show)

type Header = (HeaderName, ByteString)

type Headers = [Header]

type BodyBytes = ByteString

type RawPath = ByteString

data Request = Request
  { requestMethod :: Method
  , requestPath :: [String]
  , requestQuery :: [(String, String)]
  , requestHeaders :: Headers
  , requestBody :: BodyBytes
  , requestRawPath :: RawPath
  } deriving (Eq, Show)

data Response = Response
  { responseStatus :: Status
  , responseHeaders :: Headers
  , responseBody :: ResponseBody
  } deriving (Eq, Show)

data ResponseBody
  = StrictBody ByteString
  | FileBody FilePath
  deriving (Eq, Show)

data Status = Status
  { statusCode :: Int
  , statusReason :: String
  } deriving (Eq, Show)

okStatus :: Status
okStatus = Status 200 "OK"

normaliseHeaderName :: ByteString -> HeaderName
normaliseHeaderName name =
  HeaderName (BS.pack (map lowerAscii (BS.unpack name)))

lowerAscii :: Char -> Char
lowerAscii c
  | 'A' <= c && c <= 'Z' = toEnum (fromEnum c + 32)
  | otherwise = c
