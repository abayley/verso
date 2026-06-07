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
            response <- appForTest (request GET ["documents", "home", "edit"] "")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
            bodyText response `shouldInclude` "<script src=\"/static/editor/markdown-editor.js\"></script>"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"visual\" src=\"/documents/home\"></markdown-editor>"
            bodyText response `shouldInclude` "<input type=\"hidden\" name=\"markdown\" id=\"markdown-field\">"
            bodyText response `shouldNotInclude` "# Hello from MicroHttp"
        it "given source mode editor request, when routing, then source mode is selected" $ do
            response <- appForTest ((request GET ["documents", "home", "edit"] ""){requestQuery = [("mode", "source")]})
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"source\" src=\"/documents/home\"></markdown-editor>"
        it "given markdown form post, when routing, then save status fragment is returned" $ do
            response <- appForTest (request POST ["documents", "home"] "markdown=%23+Saved+heading")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading</p>"
        it "given source markdown form post, when routing, then exact markdown is returned" $ do
            response <- appForTest (request POST ["documents", "home"] "markdown=%23+Saved+heading%0A%0AExact+paragraph.")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading\n\nExact paragraph.</p>"
        it "given raw html form post, when routing, then validation fragment is returned" $ do
            response <- appForTest (request POST ["documents", "home"] "markdown=%3Cscript%3Ealert(1)%3C%2Fscript%3E")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Unsupported Markdown: raw HTML is not supported in this spike.</p>"
        it "given unsupported markdown form post, when routing, then validation fragment is returned" $ do
            response <- appForTest (request POST ["documents", "home"] "markdown=%3E+quote")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Unsupported Markdown: unsupported block syntax.</p>"
        it "given saved markdown document, when routing document page, then raw markdown is returned" $ do
            response <- appForTest (request GET ["documents", "home"] "")
            statusCode (responseStatus response) `shouldBe` 200
            responseHeaders response `shouldBe` [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/markdown")]
            bodyText response `shouldBe` "# Hello from MicroHttp\n\nEdit this Markdown document."
        it "given markdown preview post, when routing preview, then preview endpoint is not found" $ do
            response <- appForTest (request POST ["documents", "home", "preview"] "markdown=%23+Preview+heading%0A%0APreview+paragraph.")
            statusCode (responseStatus response) `shouldBe` 404
        it "given editor script request, when routing, then static script file response is returned" $ do
            response <- appForTest (request GET ["static", "editor", "markdown-editor.js"] "")
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

appForTest :: Request -> IO Response
appForTest =
    TestApp.appWithStore
        TestApp.DocumentStore
            { TestApp.loadDocument = \_ -> return "# Hello from MicroHttp\n\nEdit this Markdown document."
            , TestApp.saveDocumentContent = \_ _ -> return ()
            }

bodyText :: Response -> String
bodyText response =
    case responseBody response of
        StrictBody body -> BS.unpack body
        FileBody path -> path

shouldInclude :: String -> String -> Expectation
shouldInclude actual expected =
    isInfixOf expected actual `shouldBe` True

shouldNotInclude :: String -> String -> Expectation
shouldNotInclude actual expected =
    isInfixOf expected actual `shouldBe` False
