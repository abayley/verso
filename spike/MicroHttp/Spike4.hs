module MicroHttp.Spike4(main) where

import MicroHttp.Http
import MicroHttp.Response

main :: IO ()
main = do
  assertEqual "response serialisation" expected (serialiseResponse response)
  putStrLn "spike 4 response checks passed"

response :: Response
response =
  Response
    201
    "Created"
    [("Content-Type", "text/html"), ("HX-Trigger", "item-created")]
    "<li>created</li>"

expected :: String
expected =
  "HTTP/1.1 201 Created\r\n" ++
  "Content-Type: text/html\r\n" ++
  "HX-Trigger: item-created\r\n" ++
  "Content-Length: 16\r\n" ++
  "Connection: close\r\n" ++
  "\r\n" ++
  "<li>created</li>"

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expectedValue actual =
  if expectedValue == actual then
    return ()
  else
    error (label ++ " expected " ++ show expectedValue ++ " but got " ++ show actual)
