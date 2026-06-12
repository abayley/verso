module MicroHttp.RouterSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Iteratee (Iter, run, strictEnumerator)
import MicroHttp.Router
import MicroHttp.Stream (StreamError)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Router" $ do
        it "given literal route, when routing, then literal handler response is returned" $ do
            literal <- routed (request GET ["todos"])
            fmap responseBody literal `shouldBe` Right (StrictBody (bs "index"))
        it "given capture route, when routing, then capture is passed to handler" $ do
            captured <- routed (request GET ["todos", "42"])
            fmap responseBody captured `shouldBe` Right (StrictBody (bs "show 42"))
        it "given POST route, when routing, then POST handler response is returned" $ do
            created <- routed (request POST ["todos"])
            fmap responseBody created `shouldBe` Right (StrictBody (bs "create"))
        it "given no matching path, when routing, then not found response is returned" $ do
            missing <- routed (request GET ["missing"])
            fmap (statusCode . responseStatus) missing `shouldBe` Right 404
        it "given matching path with wrong method, when routing, then method not allowed is returned" $ do
            wrongMethod <- routed (request DELETE ["todos"])
            fmap (statusCode . responseStatus) wrongMethod `shouldBe` Right 405
        it "given a wildcard route, when routing a deeper path, then the remainder is captured joined" $ do
            wild <- routed (request GET ["static", "css", "app.css"])
            fmap responseBody wild `shouldBe` Right (StrictBody (bs "css/app.css"))
        it "given a wildcard route, when routing the bare prefix, then the remainder is empty" $ do
            wild <- routed (request GET ["static"])
            fmap responseBody wild `shouldBe` Right (StrictBody (bs ""))

-- | Runs the router over an empty body and extracts the response.
routed :: RequestHead -> IO (Either StreamError Response)
routed head = strictEnumerator (bs "") (route routes head) >>= run

routes :: [Route]
routes =
    [ get "/todos" (\_ _ -> pureText "index")
    , get "/todos/:id" (\captures _ -> pureText ("show " ++ capture "id" captures))
    , post "/todos" (\_ _ -> pureText "create")
    , get "/static/*path" (\captures _ -> pureText (capture "path" captures))
    ]

pureText :: String -> Iter StreamError Response
pureText body =
    pure (Response okStatus [] (StrictBody (bs body)))

request :: Method -> [String] -> RequestHead
request method path =
    RequestHead
        { requestMethod = method
        , requestPath = path
        , requestQuery = []
        , requestHeaders = []
        , requestRawPath = bs "/"
        }

capture :: String -> Captures -> String
capture _ [] = ""
capture name ((key, value) : rest)
    | name == key = value
    | otherwise = capture name rest

bs :: String -> BS.ByteString
bs = BS.pack
