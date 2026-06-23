module MicroHttp.TestAppSpec (spec) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf)
import MicroHttp.Http
import MicroHttp.Iteratee (Iter, run, strictEnumerator)
import qualified MicroHttp.Router as Router
import MicroHttp.Stream (StreamError)
import qualified MicroHttp.TestApp as TestApp
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
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

        describe "navigation tree (RFC-0026)" $ do
            it "given a directory entry, when classified, then sidecars, dotfiles, non-markdown, and index.md are hidden" $ do
                TestApp.treeEntryKind "alpha" True `shouldBe` Just TestApp.Section
                TestApp.treeEntryKind "page.md" False `shouldBe` Just TestApp.Page
                TestApp.treeEntryKind "index.md" False `shouldBe` Nothing
                TestApp.treeEntryKind "meta" True `shouldBe` Nothing
                TestApp.treeEntryKind "assets" True `shouldBe` Nothing
                TestApp.treeEntryKind ".DS_Store" False `shouldBe` Nothing
                TestApp.treeEntryKind "notes.txt" False `shouldBe` Nothing

            it "given sibling nodes, when ordered, then sections precede pages, alphabetical within each" $ do
                let node k nm = TestApp.TreeNode nm nm k False
                map
                    TestApp.nodeName
                    ( TestApp.orderTreeNodes
                        [ node TestApp.Page "zebra.md"
                        , node TestApp.Section "Beta"
                        , node TestApp.Page "Apple"
                        , node TestApp.Section "alpha"
                        ]
                    )
                    `shouldBe` ["alpha", "Beta", "Apple", "zebra.md"]

            it "given nodes, when serialised, then the json carries name, path, kind, and hasChildren" $ do
                TestApp.treeChildrenJson [TestApp.TreeNode "Alpha" "alpha" TestApp.Section True]
                    `shouldBe` "[{\"name\":\"Alpha\",\"path\":\"alpha\",\"kind\":\"section\",\"hasChildren\":true}]"

            it "given the tree root, when children read, then sections come first then pages, index.md folded and sidecars hidden" $ do
                treeRoot <- setupTreeFixture
                nodes <- TestApp.childrenOf treeRoot ""
                map nodeTuple nodes
                    `shouldBe` [ ("Alpha", TestApp.Section, "alpha", True)
                               , ("Beta", TestApp.Section, "beta", True)
                               , ("Empty Section", TestApp.Section, "empty", False)
                               , ("Home Page", TestApp.Page, "home.md", False)
                               ]

            it "given a subsection, when children read, then its page is labelled by frontmatter and index.md is folded" $ do
                treeRoot <- setupTreeFixture
                nodes <- TestApp.childrenOf treeRoot "alpha"
                map (\nd -> (TestApp.nodeName nd, TestApp.nodePath nd)) nodes
                    `shouldBe` [("Alpha Page", "alpha/page.md")]

            it "given a section holding only index.md, when children read, then there are none" $ do
                treeRoot <- setupTreeFixture
                nodes <- TestApp.childrenOf treeRoot "empty"
                nodes `shouldBe` []

            it "given an unsafe path, when children read, then none are returned" $ do
                treeRoot <- setupTreeFixture
                nodes <- TestApp.childrenOf treeRoot "../secret"
                nodes `shouldBe` []

            it "given GET /tree, when routed against the tree, then the root children are returned as json" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeApp treeRoot (request GET ["tree"])
                statusCode (responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"name\":\"Alpha\",\"path\":\"alpha\",\"kind\":\"section\""
                bodyText response `shouldInclude` "\"name\":\"Home Page\",\"path\":\"home.md\",\"kind\":\"page\""

            it "given a page read against the tree, when rendered, then the editor embeds the navigation spine" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeApp treeRoot (request GET ["documents", "alpha", "page.md"])
                bodyText response `shouldInclude` "data-tree-spine="
                bodyText response `shouldInclude` "Alpha Page"
                bodyText response `shouldInclude` "Beta"

            it "given a title, when slugified, then it is lower-cased kebab-case with runs collapsed and trimmed" $ do
                TestApp.slugify "Network Delivery" `shouldBe` "network-delivery"
                TestApp.slugify "  A: B & C!  " `shouldBe` "a-b-c"
                TestApp.slugify "!!!" `shouldBe` "untitled"

            it "given POST /tree create page, when routed, then the seeded page is written and returned, and appears in the tree" $ do
                treeRoot <- setupTreeFixture
                cleanFile (treeRoot ++ "/alpha/created-page.md")
                response <- runTreeAppBody treeRoot (request POST ["tree", "alpha"]) "kind=page&title=Created+Page"
                statusCode (responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"path\":\"alpha/created-page.md\""
                bodyText response `shouldInclude` "\"editPath\":\"alpha/created-page.md\""
                bodyText response `shouldInclude` "\"kind\":\"page\""
                written <- readFile (treeRoot ++ "/alpha/created-page.md")
                written `shouldBe` "---\nname: Created Page\n---\n\n# Created Page\n"
                nodes <- TestApp.childrenOf treeRoot "alpha"
                map TestApp.nodeName nodes `shouldBe` ["Alpha Page", "Created Page"]
                cleanFile (treeRoot ++ "/alpha/created-page.md")

            it "given POST /tree create with no title, when routed, then it is a bad request" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeAppBody treeRoot (request POST ["tree", "alpha"]) "kind=page&title="
                statusCode (responseStatus response) `shouldBe` 400

nodeTuple :: TestApp.TreeNode -> (String, TestApp.NodeKind, String, Bool)
nodeTuple nd =
    (TestApp.nodeName nd, TestApp.nodeKind nd, TestApp.nodePath nd, TestApp.nodeHasChildren nd)

{- | Builds (idempotently) a small document tree under @build/@ for the
navigation-tree IO and routing tests, and returns its root.
-}
setupTreeFixture :: IO FilePath
setupTreeFixture = do
    let root = "build/tree-spec"
        seed name title = "---\nname: " ++ title ++ "\n---\n\n# " ++ title ++ "\n"
    createDirectoryIfMissing True (root ++ "/alpha")
    createDirectoryIfMissing True (root ++ "/beta/sub")
    createDirectoryIfMissing True (root ++ "/empty")
    createDirectoryIfMissing True (root ++ "/meta")
    createDirectoryIfMissing True (root ++ "/assets")
    writeFile (root ++ "/index.md") (seed "index" "Cello Docs")
    writeFile (root ++ "/home.md") (seed "home" "Home Page")
    writeFile (root ++ "/notes.txt") "not markdown\n"
    writeFile (root ++ "/.DS_Store") "junk\n"
    writeFile (root ++ "/alpha/index.md") (seed "alpha" "Alpha")
    writeFile (root ++ "/alpha/page.md") (seed "alpha-page" "Alpha Page")
    writeFile (root ++ "/beta/index.md") (seed "beta" "Beta")
    writeFile (root ++ "/beta/sub/index.md") (seed "beta-sub" "Beta Sub")
    writeFile (root ++ "/empty/index.md") (seed "empty" "Empty Section")
    writeFile (root ++ "/meta/meta.yaml") "x: y\n"
    writeFile (root ++ "/assets/diagram.png") "binary\n"
    pure root

{- | Runs the tree-serving routes (RFC-0026) over a request head against a real
filesystem root, returning the response.
-}
runTreeApp :: FilePath -> RequestHead -> IO Response
runTreeApp root head = runTreeAppBody root head ""

-- | As 'runTreeApp', with a request body (for create posts).
runTreeAppBody :: FilePath -> RequestHead -> String -> IO Response
runTreeAppBody root head body = do
    outcome <- strictEnumerator (BS.pack body) (Router.route (TestApp.treeRoutes "paper" root) head) >>= run
    case outcome of
        Right response -> return response
        Left err -> expectFailure err

-- | Removes a file if it exists (test cleanup).
cleanFile :: FilePath -> IO ()
cleanFile f = do
    exists <- doesFileExist f
    when exists (removeFile f)

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
