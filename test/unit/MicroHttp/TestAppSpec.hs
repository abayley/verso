module MicroHttp.TestAppSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf)
import MicroHttp.Http
import MicroHttp.Iteratee (Iter, run, strictEnumerator)
import qualified MicroHttp.Router as Router
import MicroHttp.Stream (StreamError)
import qualified MicroHttp.TestApp as TestApp
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.TestApp" $ do
        it "given editor request, when routing, then markdown editor page is returned" $ do
            response <- runApp (request GET ["documents", "home", "edit"]) ""
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<html lang=\"en\" class=\"wa-theme-default wa-palette-default wa-brand-blue\">"
            bodyText response `shouldInclude` "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
            bodyText response `shouldInclude` "<script src=\"/static/editor/markdown-editor.js\"></script>"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/webawesome.css\">"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            bodyText response `shouldInclude` "hx-trigger=\"submit, editor:changed delay:2s from:markdown-editor\""
            bodyText response `shouldInclude` "hx-swap=\"none\""
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"visual\" src=\"/documents/home\"></markdown-editor>"
            bodyText response `shouldInclude` "<input type=\"hidden\" name=\"markdown\" id=\"markdown-field\">"
            bodyText response `shouldNotInclude` "id=\"save-status\""
            bodyText response `shouldNotInclude` "# Hello from MicroHttp"
        it "given source mode editor request, when routing, then source mode is selected" $ do
            response <- runApp ((request GET ["documents", "home", "edit"]){requestQuery = [("mode", "source")]}) ""
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"source\" src=\"/documents/home\"></markdown-editor>"
        it "given split mode editor request, when routing, then split mode is selected" $ do
            response <- runApp ((request GET ["documents", "home", "edit"]){requestQuery = [("mode", "split")]}) ""
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" mode=\"split\" src=\"/documents/home\"></markdown-editor>"
        it "given markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%23+Saved+heading"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading</p>"
        it "given source markdown form post, when routing, then exact markdown is returned" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%23+Saved+heading%0A%0AExact+paragraph."
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading\n\nExact paragraph.</p>"
        it "given fenced code markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%60%60%60typescript%0Aconst+value+%3D+1%3B%0A%60%60%60"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: ```typescript\nconst value = 1;\n```</p>"
        it "given blockquote markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%3E+Quoted+text."
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: &gt; Quoted text.</p>"
        it "given blockquoted ordered list with fenced code, when routing, then save status fragment is returned" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%3E+1.+xxx%0A%3E+2.+yyy%0A%3E++++%0A%3E++++%60%60%60typescript%0A%3E++++export+type+EditorBlock+%3D+BlockquoteBlock+%7C+CodeBlock+%7C+HeadingBlock+%7C+HorizontalRuleBlock+%7C+ListBlock+%7C+ParagraphBlock%3B%0A%3E++++%60%60%60"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "Saved Markdown document: &gt; 1. xxx"
            bodyText response `shouldInclude` "export type EditorBlock"
        it "given raw html form post, when routing, then validation fragment is returned" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Unsupported Markdown: raw HTML is not supported in this spike.</p>"
        it "given unsupported markdown form post, when routing, then validation fragment is returned" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%60%60%60typescript%0Aunterminated"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Unsupported Markdown: unsupported block syntax.</p>"
        it "given saved markdown document, when routing document page, then raw markdown is returned" $ do
            response <- runApp (request GET ["documents", "home"]) ""
            statusCode (responseStatus response) `shouldBe` 200
            responseHeaders response `shouldBe` [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/markdown")]
            bodyText response `shouldBe` "# Hello from MicroHttp\n\nEdit this Markdown document."
        it "given markdown preview post, when routing preview, then preview endpoint is not found" $ do
            response <- runApp (request POST ["documents", "home", "preview"]) "markdown=%23+Preview+heading%0A%0APreview+paragraph."
            statusCode (responseStatus response) `shouldBe` 404

request :: Method -> [String] -> RequestHead
request method path =
    RequestHead
        { requestMethod = method
        , requestPath = path
        , requestQuery = []
        , requestHeaders = []
        , requestRawPath = BS.pack "/"
        }

{- | Runs the test application over a request head and body, returning the
response (failing the example on a stream error).
-}
runApp :: RequestHead -> String -> IO Response
runApp head body = do
    outcome <- strictEnumerator (BS.pack body) (testApp head) >>= run
    case outcome of
        Right response -> return response
        Left err -> expectFailure err

{- | Drives the routes at the handler level (a parsed head in), bypassing
framing, so the tests can pass a 'RequestHead' directly. The store is in
memory, so this stays a unit test with no filesystem effects.
-}
testApp :: RequestHead -> Iter StreamError Response
testApp =
    Router.route
        ( TestApp.routes
            TestApp.DocumentStore
                { TestApp.loadDocument = \_ -> return "# Hello from MicroHttp\n\nEdit this Markdown document."
                , TestApp.saveDocumentContent = \_ _ -> return ()
                }
        )

expectFailure :: StreamError -> IO Response
expectFailure err = do
    expect ("unexpected stream failure: " ++ show err) False
    return (Response okStatus [] (StrictBody (BS.pack "")))

bodyText :: Response -> String
bodyText response =
    case responseBody response of
        StrictBody body -> BS.unpack body
        StreamBody _ -> "<stream>"

shouldInclude :: String -> String -> Expectation
shouldInclude actual expected =
    isInfixOf expected actual `shouldBe` True

shouldNotInclude :: String -> String -> Expectation
shouldNotInclude actual expected =
    isInfixOf expected actual `shouldBe` False
