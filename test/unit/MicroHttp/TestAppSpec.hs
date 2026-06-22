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
            bodyText response `shouldInclude` "class=\"wa-theme-default wa-palette-default wa-brand-blue\""
            bodyText response `shouldInclude` "data-editor-theme=\"paper\""
            bodyText response `shouldInclude` "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
            bodyText response `shouldInclude` "<script src=\"/static/editor/markdown-editor.js\"></script>"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/webawesome.css\">"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            bodyText response `shouldInclude` "hx-trigger=\"submit, editor:changed delay:2s from:markdown-editor\""
            bodyText response `shouldInclude` "hx-swap=\"none\""
            bodyText response `shouldInclude` "action=\"/documents/home\""
            bodyText response `shouldInclude` "method=\"post\""
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" data-document=\"home\">"
            bodyText response `shouldInclude` "<textarea name=\"markdown\" aria-label=\"Markdown source\" class=\"markdown-editor__fallback\">"
            bodyText response `shouldInclude` "# Hello from MicroHttp\n\nEdit this Markdown document."
            bodyText response `shouldInclude` "<noscript><button type=\"submit\">Save</button></noscript>"
            bodyText response `shouldNotInclude` "src=\"/documents/home\""
            bodyText response `shouldNotInclude` "id=\"markdown-field\""
            bodyText response `shouldNotInclude` "id=\"save-status\""
        it "given a configured editor theme default, when routing the editor, then it is emitted on the page" $ do
            response <- runThemedApp "aurora" (request GET ["documents", "home", "edit"])
            bodyText response `shouldInclude` "data-editor-theme=\"aurora\""
        it "given the studio editor theme default, when routing the editor, then it is emitted on the page" $ do
            response <- runThemedApp "studio" (request GET ["documents", "home", "edit"])
            bodyText response `shouldInclude` "data-editor-theme=\"studio\""
        it "given an unknown configured editor theme default, when routing the editor, then it falls back to paper" $ do
            response <- runThemedApp "bogus-theme" (request GET ["documents", "home", "edit"])
            bodyText response `shouldInclude` "data-editor-theme=\"paper\""
        it "given source mode editor request, when routing, then source mode is selected" $ do
            response <- runApp ((request GET ["documents", "home", "edit"]){requestQuery = [("mode", "source")]}) ""
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" data-document=\"home\" mode=\"source\">"
        it "given split mode editor request, when routing, then split mode is selected" $ do
            response <- runApp ((request GET ["documents", "home", "edit"]){requestQuery = [("mode", "split")]}) ""
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" data-document=\"home\" mode=\"split\">"
        it "given markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%23+Saved+heading"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading</p>"
        it "given source markdown form post, when routing, then exact markdown is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%23+Saved+heading%0A%0AExact+paragraph."
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading\n\nExact paragraph.</p>"
        it "given fenced code markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%60%60%60typescript%0Aconst+value+%3D+1%3B%0A%60%60%60"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: ```typescript\nconst value = 1;\n```</p>"
        it "given blockquote markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%3E+Quoted+text."
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: &gt; Quoted text.</p>"
        it "given blockquoted ordered list with fenced code, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%3E+1.+xxx%0A%3E+2.+yyy%0A%3E++++%0A%3E++++%60%60%60typescript%0A%3E++++export+type+EditorBlock+%3D+BlockquoteBlock+%7C+CodeBlock+%7C+HeadingBlock+%7C+HorizontalRuleBlock+%7C+ListBlock+%7C+ParagraphBlock%3B%0A%3E++++%60%60%60"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "Saved Markdown document: &gt; 1. xxx"
            bodyText response `shouldInclude` "export type EditorBlock"
        it "given raw html form post, when routing, then validation fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Unsupported Markdown: raw HTML is not supported in this spike.</p>"
        it "given markdown the former block guard rejected, when routing, then it is now saved (guard narrowed to raw HTML only)" $ do
            -- An unterminated code fence was rejected as "unsupported block syntax" before RFC-0017;
            -- block-structure validation is gone (the editor owns its open subset), so it now saves.
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%60%60%60typescript%0Aunterminated"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: ```typescript\nunterminated</p>"
        it "given a form post with CRLF newlines, when saving, then they are normalised to line feeds" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=Line+one%0D%0A%0D%0ALine+two"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: Line one\n\nLine two</p>"
        it "given a non-htmx valid post, when saving, then it redirects to the edit page" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%23+Saved+heading"
            statusCode (responseStatus response) `shouldBe` 303
            responseHeaders response `shouldBe` [(normaliseHeaderName (BS.pack "Location"), BS.pack "/documents/home/edit")]
        it "given a non-htmx invalid post, when validating, then the edit page is re-rendered with the message and the escaped submission" $ do
            response <- runApp (request POST ["documents", "home"]) "markdown=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
            statusCode (responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "Unsupported Markdown: raw HTML is not supported in this spike."
            bodyText response `shouldInclude` "<textarea name=\"markdown\""
            bodyText response `shouldInclude` "&lt;script&gt;alert(1)&lt;/script&gt;"
        it "given saved markdown document, when routing document page, then raw markdown is returned" $ do
            response <- runApp (request GET ["documents", "home"]) ""
            statusCode (responseStatus response) `shouldBe` 200
            responseHeaders response `shouldBe` [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/markdown")]
            bodyText response `shouldBe` "# Hello from MicroHttp\n\nEdit this Markdown document."
        it "given markdown preview post, when routing preview, then preview endpoint is not found" $ do
            response <- runApp (request POST ["documents", "home", "preview"]) "markdown=%23+Preview+heading%0A%0APreview+paragraph."
            statusCode (responseStatus response) `shouldBe` 404

        it "given frontmatter with a name, when read, then the title is returned (quotes stripped)" $ do
            TestApp.frontmatterTitle "---\nname: Engineering\nmeta: x\n---\n\n# Body" `shouldBe` Just "Engineering"
            TestApp.frontmatterTitle "---\nname: \"A: title\"\n---" `shouldBe` Just "A: title"

        it "given no frontmatter or no name, when read, then Nothing is returned" $ do
            TestApp.frontmatterTitle "# Just a body\n" `shouldBe` Nothing
            TestApp.frontmatterTitle "---\nmeta: x\n---" `shouldBe` Nothing

        it "given a regular page path, when linked folders computed, then root and each ancestor folder are linked" $ do
            TestApp.linkedFolderPaths "engineering/hpearuba-guides/aruba-central-troubleshooting/noc.md"
                `shouldBe` ["", "engineering", "engineering/hpearuba-guides", "engineering/hpearuba-guides/aruba-central-troubleshooting"]

        it "given a folder index page, when linked folders computed, then its own folder is not linked (it is the current page)" $ do
            TestApp.linkedFolderPaths "engineering/index.md" `shouldBe` [""]
            TestApp.linkedFolderPaths "engineering/a/index.md" `shouldBe` ["", "engineering"]

        it "given the root index page, when linked folders computed, then there are no ancestor links" $ do
            TestApp.linkedFolderPaths "index.md" `shouldBe` []

request :: Method -> [String] -> RequestHead
request method path =
    emptyRequestHead
        { requestMethod = method
        , requestPath = path
        }

-- | A POST carrying the @hx-request@ header, as htmx sends.
htmxPost :: [String] -> RequestHead
htmxPost path =
    (request POST path)
        { requestHeaders = [(normaliseHeaderName (BS.pack "hx-request"), BS.pack "true")]
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
testApp = themedApp "paper"

-- | Routes through the test store with a chosen editor theme default.
themedApp :: String -> RequestHead -> Iter StreamError Response
themedApp themeDefault =
    Router.route (TestApp.routes themeDefault testStore)

testStore :: TestApp.DocumentStore
testStore =
    TestApp.DocumentStore
        { TestApp.loadDocument = \_ -> return "# Hello from MicroHttp\n\nEdit this Markdown document."
        , TestApp.saveDocumentContent = \_ _ -> return ()
        }

-- | Renders the editor page for a request through an app with the given theme default.
runThemedApp :: String -> RequestHead -> IO Response
runThemedApp themeDefault head = do
    outcome <- strictEnumerator (BS.pack "") (themedApp themeDefault head) >>= run
    case outcome of
        Right response -> return response
        Left err -> expectFailure err

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
