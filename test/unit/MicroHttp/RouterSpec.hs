module MicroHttp.RouterSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Router
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Router" $ do
        it "given literal route, when routing, then literal handler response is returned" $ do
            literal <- route routes (request GET ["todos"])
            responseBody literal `shouldBe` StrictBody (bs "index")
        it "given capture route, when routing, then capture is passed to handler" $ do
            captured <- route routes (request GET ["todos", "42"])
            responseBody captured `shouldBe` StrictBody (bs "show 42")
        it "given POST route, when routing, then POST handler response is returned" $ do
            created <- route routes (request POST ["todos"])
            responseBody created `shouldBe` StrictBody (bs "create")
        it "given no matching path, when routing, then not found response is returned" $ do
            missing <- route routes (request GET ["missing"])
            statusCode (responseStatus missing) `shouldBe` 404
        it "given matching path with wrong method, when routing, then method not allowed is returned" $ do
            wrongMethod <- route routes (request DELETE ["todos"])
            statusCode (responseStatus wrongMethod) `shouldBe` 405

routes :: [Route]
routes =
    [ get "/todos" (\_ _ -> pureText "index")
    , get "/todos/:id" (\captures _ -> pureText ("show " ++ capture "id" captures))
    , post "/todos" (\_ _ -> pureText "create")
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
capture name ((key, value) : rest)
    | name == key = value
    | otherwise = capture name rest

bs :: String -> BS.ByteString
bs = BS.pack
