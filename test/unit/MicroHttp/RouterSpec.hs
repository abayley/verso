module MicroHttp.RouterSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Stream as Stream
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Router" $ do
        it "given literal route, when routing, then literal handler response is returned" $ do
            literal <- routed (request Http.GET ["todos"])
            fmap Http.responseBody literal `shouldBe` Right (Http.StrictBody (bs "index"))
        it "given capture route, when routing, then capture is passed to handler" $ do
            captured <- routed (request Http.GET ["todos", "42"])
            fmap Http.responseBody captured `shouldBe` Right (Http.StrictBody (bs "show 42"))
        it "given POST route, when routing, then POST handler response is returned" $ do
            created <- routed (request Http.POST ["todos"])
            fmap Http.responseBody created `shouldBe` Right (Http.StrictBody (bs "create"))
        it "given no matching path, when routing, then not found response is returned" $ do
            missing <- routed (request Http.GET ["missing"])
            fmap (Http.statusCode . Http.responseStatus) missing `shouldBe` Right 404
        it "given matching path with wrong method, when routing, then method not allowed is returned" $ do
            wrongMethod <- routed (request Http.DELETE ["todos"])
            fmap (Http.statusCode . Http.responseStatus) wrongMethod `shouldBe` Right 405
        it "given a wildcard route, when routing a deeper path, then the remainder is captured joined" $ do
            wild <- routed (request Http.GET ["static", "css", "app.css"])
            fmap Http.responseBody wild `shouldBe` Right (Http.StrictBody (bs "css/app.css"))
        it "given a wildcard route, when routing the bare prefix, then the remainder is empty" $ do
            wild <- routed (request Http.GET ["static"])
            fmap Http.responseBody wild `shouldBe` Right (Http.StrictBody (bs ""))

-- | Runs the router over an empty body and extracts the response.
routed :: Http.RequestHead -> IO (Either Stream.StreamError Http.Response)
routed head = Iteratee.strictEnumerator (bs "") (Router.route routes head) >>= Iteratee.run

routes :: [Router.Route]
routes =
    [ Router.get "/todos" (\_ _ -> pureText "index")
    , Router.get "/todos/:id" (\captures _ -> pureText ("show " ++ capture "id" captures))
    , Router.post "/todos" (\_ _ -> pureText "create")
    , Router.get "/static/*path" (\captures _ -> pureText (capture "path" captures))
    ]

pureText :: String -> Iteratee.Iter Stream.StreamError Http.Response
pureText body =
    pure (Http.Response Http.okStatus [] (Http.StrictBody (bs body)))

request :: Http.Method -> [String] -> Http.RequestHead
request method path =
    Http.emptyRequestHead
        { Http.requestMethod = method
        , Http.requestPath = path
        }

capture :: String -> Router.Captures -> String
capture _ [] = ""
capture name ((key, value) : rest)
    | name == key = value
    | otherwise = capture name rest

bs :: String -> BS.ByteString
bs = BS.pack
