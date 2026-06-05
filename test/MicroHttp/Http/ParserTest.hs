module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Http.Parser

main :: IO ()
main = do
  assertEqual
    "given GET request, when parsing, then request fields are returned"
    (Right Request
      { requestMethod = GET
      , requestPath = ["todos", "open items"]
      , requestQuery = [("filter", "open now")]
      , requestHeaders = [(normaliseHeaderName (bs "Host"), bs "localhost")]
      , requestBody = bs ""
      , requestRawPath = bs "/todos/open%20items"
      })
    (parseRequest
      defaultParseLimits
      (bs "GET /todos/open%20items?filter=open%20now HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  assertEqual
    "given POST request with content length, when parsing, then request body is returned"
    (Right Request
      { requestMethod = POST
      , requestPath = ["todos"]
      , requestQuery = []
      , requestHeaders =
          [ (normaliseHeaderName (bs "Content-Length"), bs "11")
          , (normaliseHeaderName (bs "Content-Type"), bs "application/x-www-form-urlencoded")
          ]
      , requestBody = bs "title=Hello"
      , requestRawPath = bs "/todos"
      })
    (parseRequest
      defaultParseLimits
      (bs "POST /todos HTTP/1.1\r\nContent-Length: 11\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\ntitle=Helloignored"))
  assertEqual
    "given unsupported method, when parsing, then unsupported method error is returned"
    (Left (UnsupportedMethod (bs "PROPFIND")))
    (parseRequest defaultParseLimits (bs "PROPFIND /todos HTTP/1.1\r\n\r\n"))
  assertEqual
    "given unsupported HTTP version, when parsing, then unsupported version error is returned"
    (Left UnsupportedHttpVersion)
    (parseRequest defaultParseLimits (bs "GET /todos HTTP/2.0\r\n\r\n"))
  assertEqual
    "given malformed request line, when parsing, then bad request error is returned"
    (Left (BadRequest "invalid request line"))
    (parseRequest defaultParseLimits (bs "GET /todos\r\n\r\n"))
  assertEqual
    "given oversized headers, when parsing, then header too large error is returned"
    (Left HeaderTooLarge)
    (parseRequest (ParseLimits 4 100) (bs "GET / HTTP/1.1\r\n\r\n"))
  assertEqual
    "given oversized body, when parsing, then body too large error is returned"
    (Left BodyTooLarge)
    (parseRequest (ParseLimits 1000 4) (bs "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"))
  assertEqual
    "given chunked transfer encoding, when parsing, then unsupported transfer encoding is returned"
    (Left UnsupportedTransferEncoding)
    (parseRequest defaultParseLimits (bs "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))

bs :: String -> BS.ByteString
bs = BS.pack

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expected ++ ", got " ++ show actual)
