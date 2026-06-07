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
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"visual\">"
            bodyText response `shouldInclude` "<input type=\"hidden\" name=\"markdown\" id=\"markdown-field\">"
            bodyText response `shouldInclude` "# Hello from MicroHttp"
        it "given source mode editor request, when routing, then source mode is selected" $ do
            response <- appForTest ((request GET ["documents", "home", "edit"] ""){requestQuery = [("mode", "source")]})
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"source\">"
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
        it "given saved markdown document, when routing document page, then rendered document html is returned" $ do
            response <- appForTest (request GET ["documents", "home"] "")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<h1>Hello from MicroHttp</h1>"
            bodyText response `shouldInclude` "<p>Edit this Markdown document.</p>"
        it "given markdown preview post, when routing preview, then rendered preview fragment is returned" $ do
            response <- appForTest (request POST ["documents", "home", "preview"] "markdown=%23+Preview+heading%0A%0APreview+paragraph.")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<div id=\"preview\"><h1>Preview heading</h1><p>Preview paragraph.</p></div>"
        it "given inline markdown preview post, when routing preview, then inline html is returned" $ do
            response <- appForTest (request POST ["documents", "home", "preview"] "markdown=%2A%2Astrong%2A%2A+%2Aem%2A+%60code%60+%5Blink%5D(%2Ftarget)")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<div id=\"preview\"><p><strong>strong</strong> <em>em</em> <code>code</code> <a href=\"/target\">link</a></p></div>"
        it "given unordered list preview post, when routing preview, then unordered list html is returned" $ do
            response <- appForTest (request POST ["documents", "home", "preview"] "markdown=-+first%0A-+%2A%2Asecond%2A%2A")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<div id=\"preview\"><ul><li>first</li><li><strong>second</strong></li></ul></div>"
        it "given ordered list preview post, when routing preview, then ordered list html is returned" $ do
            response <- appForTest (request POST ["documents", "home", "preview"] "markdown=1.+first%0A2.+%60second%60")
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<div id=\"preview\"><ol><li>first</li><li><code>second</code></li></ol></div>"
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
