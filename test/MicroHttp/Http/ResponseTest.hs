module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Http.Response

main :: IO ()
main = do
  assertEqual
    "given strict text response, when serialising, then HTTP response bytes are returned"
    (Right (bs "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"))
    (serialiseResponse (Response okStatus [] (StrictBody (bs "hello"))))
  assertEqual
    "given response headers, when serialising, then headers are emitted before computed headers"
    (Right (bs "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"))
    (serialiseResponse
      (Response
        okStatus
        [(normaliseHeaderName (bs "Content-Type"), bs "text/plain")]
        (StrictBody (bs "ok"))))
  assertEqual
    "given file body response, when pure serialising, then file body error is returned"
    (Left CannotSerialiseFileBody)
    (serialiseResponse (Response okStatus [] (FileBody "public/app.css")))

bs :: String -> BS.ByteString
bs = BS.pack

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expected ++ ", got " ++ show actual)
