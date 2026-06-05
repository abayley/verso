module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Server

main :: IO ()
main = do
  ok <- respondToRequestBytes
    defaultSettings
    app
    (bs "GET /hello HTTP/1.1\r\n\r\n")
  assertEqual
    "given valid request bytes, when responding, then application response is returned"
    (StrictBody (bs "hello"))
    (responseBody ok)

  bad <- respondToRequestBytes
    defaultSettings
    app
    (bs "TRACE /hello HTTP/1.1\r\n\r\n")
  assertEqual
    "given parser failure, when responding, then bad request response is returned"
    400
    (statusCode (responseStatus bad))

app :: Application
app request =
  return (Response okStatus [] (StrictBody (bs (headOrEmpty (requestPath request)))))

headOrEmpty :: [String] -> String
headOrEmpty [] = ""
headOrEmpty (x:_) = x

bs :: String -> BS.ByteString
bs = BS.pack

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expected ++ ", got " ++ show actual)
