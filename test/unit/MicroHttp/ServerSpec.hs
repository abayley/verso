module MicroHttp.ServerSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Middleware (Application, withErrorResponses)
import MicroHttp.Router (get, serveRoutes)
import MicroHttp.Server
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Server" $ do
        it "given valid request bytes, when responding, then the application response is returned" $ do
            ok <- respondToRequestBytes app (bs "GET /hello HTTP/1.1\r\n\r\n")
            fmap responseBody ok `shouldBe` Right (StrictBody (bs "hello"))
        it "given a parse failure under withErrorResponses, when responding, then a 400 is returned" $ do
            bad <- respondToRequestBytes (withErrorResponses app) (bs "TRACE /hello HTTP/1.1\r\n\r\n")
            fmap (statusCode . responseStatus) bad `shouldBe` Right 400

-- | A routed application: the framing and parsing happen inside serveRoutes.
app :: Application
app =
    serveRoutes
        (parseLimits defaultSettings)
        [get "/hello" (\_ _ -> pure (Response okStatus [] (StrictBody (bs "hello"))))]

bs :: String -> BS.ByteString
bs = BS.pack
