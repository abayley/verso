module MicroHttp.Spike8(main) where

import Data.Proxy
import MicroHttp.Http
import MicroHttp.TypedRoute

type TodoShow = Lit "todos" (Capture "id" Int (End GET))

main :: IO ()
main = do
  assertEqual
    "route pattern"
    ["todos", ":id"]
    (routePattern (Proxy :: Proxy TodoShow))
  assertEqual
    "typed dispatch"
    "todo 42"
    (responseBody (dispatchTyped (Proxy :: Proxy TodoShow) todoShow requestShow))
  assertEqual
    "capture parse failure"
    404
    (responseStatus (dispatchTyped (Proxy :: Proxy TodoShow) todoShow requestBadCapture))
  putStrLn "spike 8 typed route checks passed"

todoShow :: Int -> Request -> Response
todoShow todoId _ = okText ("todo " ++ show todoId)

requestShow :: Request
requestShow = request ["todos", "42"]

requestBadCapture :: Request
requestBadCapture = request ["todos", "not-an-int"]

request :: [String] -> Request
request path =
  Request
    { requestMethod = "GET"
    , requestPath = path
    , requestQuery = []
    , requestHeaders = []
    , requestBody = ""
    , requestRawPath = "/" ++ joinWith "/" path
    }

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
