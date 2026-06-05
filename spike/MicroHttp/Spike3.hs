module MicroHttp.Spike3(main) where

import MicroHttp.Http
import MicroHttp.Parser

main :: IO ()
main = do
  assertEqual "method" "POST" (requestMethod request)
  assertEqual "path" ["todos", "42"] (requestPath request)
  assertEqual "query" [("filter", "open")] (requestQuery request)
  assertEqual "body" "title=Hello" (requestBody request)
  assertEqual "header limit" (Left HeaderTooLarge) (parseRequest 10 100 sample)
  assertEqual "body limit" (Left BodyTooLarge) (parseRequest 1000 4 sample)
  assertEqual
    "unsupported transfer encoding"
    (Left UnsupportedTransferEncoding)
    (parseRequest 1000 100 chunkedSample)
  putStrLn "spike 3 parser checks passed"
  where
    Right request = parseRequest 1000 100 sample

sample :: String
sample =
  "POST /todos/42?filter=open HTTP/1.1\r\n" ++
  "Host: example.test\r\n" ++
  "Content-Length: 11\r\n" ++
  "\r\n" ++
  "title=Hello"

chunkedSample :: String
chunkedSample =
  "POST /todos HTTP/1.1\r\n" ++
  "Transfer-Encoding: chunked\r\n" ++
  "\r\n"

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual then
    return ()
  else
    error (label ++ " expected " ++ show expected ++ " but got " ++ show actual)
