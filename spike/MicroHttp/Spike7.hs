module MicroHttp.Spike7(main) where

import MicroHttp.Http
import MicroHttp.Router

main :: IO ()
main = do
  assertEqual "literal route" "index" (responseBody (route routes requestIndex))
  assertEqual "capture route" "show 42" (responseBody (route routes requestShow))
  assertEqual "post route" "create" (responseBody (route routes requestCreate))
  assertEqual "not found" 404 (responseStatus (route routes requestMissing))
  assertEqual "method not allowed" 405 (responseStatus (route routes requestWrongMethod))
  putStrLn "spike 7 router checks passed"

routes :: [Route]
routes =
  [ get "/todos" (\ _ _ -> okText "index")
  , get "/todos/:id" (\ captures _ -> okText ("show " ++ capture "id" captures))
  , post "/todos" (\ _ _ -> okText "create")
  ]

requestIndex :: Request
requestIndex = request "GET" ["todos"]

requestShow :: Request
requestShow = request "GET" ["todos", "42"]

requestCreate :: Request
requestCreate = request "POST" ["todos"]

requestMissing :: Request
requestMissing = request "GET" ["missing"]

requestWrongMethod :: Request
requestWrongMethod = request "DELETE" ["todos"]

request :: String -> [String] -> Request
request method path =
  Request
    { requestMethod = method
    , requestPath = path
    , requestQuery = []
    , requestHeaders = []
    , requestBody = ""
    , requestRawPath = "/" ++ joinWith "/" path
    }

capture :: String -> [(String, String)] -> String
capture _ [] = ""
capture name ((key, value):rest)
  | name == key = value
  | otherwise = capture name rest

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [x] = x
joinWith separator (x:xs) = x ++ separator ++ joinWith separator xs

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual then
    return ()
  else
    error (label ++ " expected " ++ show expected ++ " but got " ++ show actual)
