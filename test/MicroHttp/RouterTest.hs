module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Router

main :: IO ()
main = do
  literal <- route routes (request GET ["todos"])
  assertEqual
    "given literal route, when routing, then literal handler response is returned"
    (StrictBody (bs "index"))
    (responseBody literal)

  captured <- route routes (request GET ["todos", "42"])
  assertEqual
    "given capture route, when routing, then capture is passed to handler"
    (StrictBody (bs "show 42"))
    (responseBody captured)

  created <- route routes (request POST ["todos"])
  assertEqual
    "given POST route, when routing, then POST handler response is returned"
    (StrictBody (bs "create"))
    (responseBody created)

  missing <- route routes (request GET ["missing"])
  assertEqual
    "given no matching path, when routing, then not found response is returned"
    404
    (statusCode (responseStatus missing))

  wrongMethod <- route routes (request DELETE ["todos"])
  assertEqual
    "given matching path with wrong method, when routing, then method not allowed is returned"
    405
    (statusCode (responseStatus wrongMethod))

routes :: [Route]
routes =
  [ get "/todos" (\ _ _ -> pureText "index")
  , get "/todos/:id" (\ captures _ -> pureText ("show " ++ capture "id" captures))
  , post "/todos" (\ _ _ -> pureText "create")
  ]

pureText :: String -> IO Response
pureText body =
  return (Response okStatus [] (StrictBody (bs body)))

request :: Method -> [String] -> Request
request method path =
  Request
    { requestMethod = method
    , requestPath = path
    , requestQuery = []
    , requestHeaders = []
    , requestBody = bs ""
    , requestRawPath = bs "/"
    }

capture :: String -> Captures -> String
capture _ [] = ""
capture name ((key, value):rest)
  | name == key = value
  | otherwise = capture name rest

bs :: String -> BS.ByteString
bs = BS.pack

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expected ++ ", got " ++ show actual)
