module MicroHttp.ServerSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Middleware as Middleware
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Server" $ do
        it "given valid request bytes, when responding, then the application response is returned" $ do
            ok <- Server.respondToRequestBytes app (bs "GET /hello HTTP/1.1\r\n\r\n")
            fmap Http.responseBody ok `shouldBe` Right (Http.StrictBody (bs "hello"))
        it "given a parse failure under withErrorResponses, when responding, then a 400 is returned" $ do
            bad <- Server.respondToRequestBytes (Middleware.withErrorResponses app) (bs "TRACE /hello HTTP/1.1\r\n\r\n")
            fmap (Http.statusCode . Http.responseStatus) bad `shouldBe` Right 400

-- | A routed application: the framing and parsing happen inside serveRoutes.
app :: Middleware.Application
app =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        [Router.get "/hello" (\_ _ -> pure (Http.Response Http.okStatus [] (Http.StrictBody (bs "hello"))))]

bs :: String -> BS.ByteString
bs = BS.pack
