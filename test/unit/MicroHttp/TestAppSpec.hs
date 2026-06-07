module MicroHttp.TestAppSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf)
import MicroHttp.Http
import qualified MicroHttp.TestApp as TestApp
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.TestApp" $ do
        it "given editor request, when routing, then markdown editor page is returned" $ do
            response <- TestApp.app (request GET ["documents", "home", "edit"] "")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
            bodyText response `shouldInclude` "<script src=\"/static/editor/markdown-editor.js\"></script>"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"visual\">"
            bodyText response `shouldInclude` "<input type=\"hidden\" name=\"markdown\" id=\"markdown-field\">"
            bodyText response `shouldInclude` "# Hello from MicroHttp"
        it "given markdown form post, when routing, then save status fragment is returned" $ do
            response <- TestApp.app (request POST ["documents", "home"] "markdown=%23+Saved+heading")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading</p>"
        it "given editor script request, when routing, then static script file response is returned" $ do
            response <- TestApp.app (request GET ["static", "editor", "markdown-editor.js"] "")
            statusCode (responseStatus response) `shouldBe` 200
            responseBody response `shouldBe` FileBody "static/editor/markdown-editor.js"

request :: Method -> [String] -> String -> Request
request method path body =
    Request
        { requestMethod = method
        , requestPath = path
        , requestQuery = []
        , requestHeaders = []
        , requestBody = BS.pack body
        , requestRawPath = BS.pack "/"
        }

bodyText :: Response -> String
bodyText response =
    case responseBody response of
        StrictBody body -> BS.unpack body
        FileBody path -> path

shouldInclude :: String -> String -> Expectation
shouldInclude actual expected =
    isInfixOf expected actual `shouldBe` True
