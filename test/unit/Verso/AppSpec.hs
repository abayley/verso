module Verso.AppSpec (spec) where

import qualified Concordance.Store as Store
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.App as App

spec :: Spec
spec =
    describe "Verso.App" $ do
        it "given editor request, when routing, then markdown editor page is returned" $ do
            response <- runApp (request Http.GET ["documents", "home", "edit"]) ""
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "class=\"wa-theme-default wa-palette-default wa-brand-blue\""
            bodyText response `shouldInclude` "data-editor-theme=\"paper\""
            bodyText response `shouldInclude` "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
            bodyText response `shouldInclude` "<script src=\"/static/editor/markdown-editor.js\"></script>"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/webawesome.css\">"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/geist.css\">"
            bodyText response `shouldInclude` "<link rel=\"stylesheet\" href=\"/static/editor/basecoat.css\">"
            bodyText response `shouldInclude` "<script src=\"/static/editor/basecoat.js\" defer></script>"
            bodyText response `shouldInclude` "window.basecoat&&window.basecoat.initAll()"
            bodyText response `shouldInclude` "htmx:afterSwap"
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
            response <- runThemedApp "aurora" (request Http.GET ["documents", "home", "edit"])
            bodyText response `shouldInclude` "data-editor-theme=\"aurora\""
        it "given the studio editor theme default, when routing the editor, then it is emitted on the page" $ do
            response <- runThemedApp "studio" (request Http.GET ["documents", "home", "edit"])
            bodyText response `shouldInclude` "data-editor-theme=\"studio\""
        it "given the shadcn editor theme default, when routing the editor, then it is emitted on the page" $ do
            response <- runThemedApp "shadcn" (request Http.GET ["documents", "home", "edit"])
            bodyText response `shouldInclude` "data-editor-theme=\"shadcn\""
        it "given an unknown configured editor theme default, when routing the editor, then it falls back to paper" $ do
            response <- runThemedApp "bogus-theme" (request Http.GET ["documents", "home", "edit"])
            bodyText response `shouldInclude` "data-editor-theme=\"paper\""
        it "given source mode editor request, when routing, then source mode is selected" $ do
            response <- runApp ((request Http.GET ["documents", "home", "edit"]){Http.requestQuery = [("mode", "source")]}) ""
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" data-document=\"home\" mode=\"source\">"
        it "given split mode editor request, when routing, then split mode is selected" $ do
            response <- runApp ((request Http.GET ["documents", "home", "edit"]){Http.requestQuery = [("mode", "split")]}) ""
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "<markdown-editor name=\"markdown\" data-document=\"home\" mode=\"split\">"
        it "given markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%23+Saved+heading"
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading</p>"
        it "given source markdown form post, when routing, then exact markdown is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%23+Saved+heading%0A%0AExact+paragraph."
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: # Saved heading\n\nExact paragraph.</p>"
        it "given fenced code markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%60%60%60typescript%0Aconst+value+%3D+1%3B%0A%60%60%60"
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: ```typescript\nconst value = 1;\n```</p>"
        it "given blockquote markdown form post, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%3E+Quoted+text."
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: &gt; Quoted text.</p>"
        it "given blockquoted ordered list with fenced code, when routing, then save status fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%3E+1.+xxx%0A%3E+2.+yyy%0A%3E++++%0A%3E++++%60%60%60typescript%0A%3E++++export+type+EditorBlock+%3D+BlockquoteBlock+%7C+CodeBlock+%7C+HeadingBlock+%7C+HorizontalRuleBlock+%7C+ListBlock+%7C+ParagraphBlock%3B%0A%3E++++%60%60%60"
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "Saved Markdown document: &gt; 1. xxx"
            bodyText response `shouldInclude` "export type EditorBlock"
        it "given raw html form post, when routing, then validation fragment is returned" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Unsupported Markdown: raw HTML is not supported in this spike.</p>"
        it "given markdown the former block guard rejected, when routing, then it is now saved (guard narrowed to raw HTML only)" $ do
            -- An unterminated code fence was rejected as "unsupported block syntax" before RFC-0017;
            -- block-structure validation is gone (the editor owns its open subset), so it now saves.
            response <- runApp (htmxPost ["documents", "home"]) "markdown=%60%60%60typescript%0Aunterminated"
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: ```typescript\nunterminated</p>"
        it "given a form post with CRLF newlines, when saving, then they are normalised to line feeds" $ do
            response <- runApp (htmxPost ["documents", "home"]) "markdown=Line+one%0D%0A%0D%0ALine+two"
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldBe` "<p id=\"save-status\">Saved Markdown document: Line one\n\nLine two</p>"
        it "given a non-htmx valid post, when saving, then it redirects to the edit page" $ do
            response <- runApp (request Http.POST ["documents", "home"]) "markdown=%23+Saved+heading"
            Http.statusCode (Http.responseStatus response) `shouldBe` 303
            Http.responseHeaders response `shouldBe` [(Http.normaliseHeaderName (BS.pack "Location"), BS.pack "/documents/home/edit")]
        it "given a non-htmx invalid post, when validating, then the edit page is re-rendered with the message and the escaped submission" $ do
            response <- runApp (request Http.POST ["documents", "home"]) "markdown=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            bodyText response `shouldInclude` "Unsupported Markdown: raw HTML is not supported in this spike."
            bodyText response `shouldInclude` "<textarea name=\"markdown\""
            bodyText response `shouldInclude` "&lt;script&gt;alert(1)&lt;/script&gt;"
        it "given saved markdown document, when routing document page, then raw markdown is returned" $ do
            response <- runApp (request Http.GET ["documents", "home"]) ""
            Http.statusCode (Http.responseStatus response) `shouldBe` 200
            Http.responseHeaders response `shouldBe` [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/markdown")]
            bodyText response `shouldBe` "# Hello from MicroHttp\n\nEdit this Markdown document."
        it "given markdown preview post, when routing preview, then preview endpoint is not found" $ do
            response <- runApp (request Http.POST ["documents", "home", "preview"]) "markdown=%23+Preview+heading%0A%0APreview+paragraph."
            Http.statusCode (Http.responseStatus response) `shouldBe` 404

        it "given frontmatter with a name, when read, then the title is returned (quotes stripped)" $ do
            App.frontmatterTitle "---\nname: Engineering\nmeta: x\n---\n\n# Body" `shouldBe` Just "Engineering"
            App.frontmatterTitle "---\nname: \"A: title\"\n---" `shouldBe` Just "A: title"

        it "given no frontmatter or no name, when read, then Nothing is returned" $ do
            App.frontmatterTitle "# Just a body\n" `shouldBe` Nothing
            App.frontmatterTitle "---\nmeta: x\n---" `shouldBe` Nothing

        it "given a regular page path, when linked folders computed, then root and each ancestor folder are linked" $ do
            App.linkedFolderPaths "engineering/hpearuba-guides/aruba-central-troubleshooting/noc.md"
                `shouldBe` ["", "engineering", "engineering/hpearuba-guides", "engineering/hpearuba-guides/aruba-central-troubleshooting"]

        it "given a folder index page, when linked folders computed, then its own folder is not linked (it is the current page)" $ do
            App.linkedFolderPaths "engineering/index.md" `shouldBe` [""]
            App.linkedFolderPaths "engineering/a/index.md" `shouldBe` ["", "engineering"]

        it "given the root index page, when linked folders computed, then there are no ancestor links" $ do
            App.linkedFolderPaths "index.md" `shouldBe` []

        describe "navigation tree (RFC-0026)" $ do
            it "given a directory entry, when classified, then sidecars, dotfiles, non-markdown, and index.md are hidden" $ do
                App.treeEntryKind "alpha" True `shouldBe` Just App.Section
                App.treeEntryKind "page.md" False `shouldBe` Just App.Page
                App.treeEntryKind "index.md" False `shouldBe` Nothing
                App.treeEntryKind "meta" True `shouldBe` Nothing
                App.treeEntryKind "assets" True `shouldBe` Nothing
                App.treeEntryKind ".DS_Store" False `shouldBe` Nothing
                App.treeEntryKind "notes.txt" False `shouldBe` Nothing

            it "given sibling nodes, when ordered, then sections precede pages, alphabetical within each" $ do
                let node k nm = App.TreeNode nm nm k False
                map
                    App.nodeName
                    ( App.orderTreeNodes
                        [ node App.Page "zebra.md"
                        , node App.Section "Beta"
                        , node App.Page "Apple"
                        , node App.Section "alpha"
                        ]
                    )
                    `shouldBe` ["alpha", "Beta", "Apple", "zebra.md"]

            it "given nodes, when serialised, then the json carries name, path, kind, and hasChildren" $ do
                App.treeChildrenJson [App.TreeNode "Alpha" "alpha" App.Section True]
                    `shouldBe` "[{\"name\":\"Alpha\",\"path\":\"alpha\",\"kind\":\"section\",\"hasChildren\":true}]"

            it "given the tree root, when children read, then sections come first then pages, index.md folded and sidecars hidden" $ do
                treeRoot <- setupTreeFixture
                nodes <- App.childrenOf treeRoot ""
                map nodeTuple nodes
                    `shouldBe` [ ("Alpha", App.Section, "alpha", True)
                               , ("Beta", App.Section, "beta", True)
                               , ("Empty Section", App.Section, "empty", False)
                               , ("Home Page", App.Page, "home.md", False)
                               ]

            it "given a subsection, when children read, then its page is labelled by frontmatter and index.md is folded" $ do
                treeRoot <- setupTreeFixture
                nodes <- App.childrenOf treeRoot "alpha"
                map (\nd -> (App.nodeName nd, App.nodePath nd)) nodes
                    `shouldBe` [("Alpha Page", "alpha/page.md")]

            it "given a section holding only index.md, when children read, then there are none" $ do
                treeRoot <- setupTreeFixture
                nodes <- App.childrenOf treeRoot "empty"
                nodes `shouldBe` []

            it "given an unsafe path, when children read, then none are returned" $ do
                treeRoot <- setupTreeFixture
                nodes <- App.childrenOf treeRoot "../secret"
                nodes `shouldBe` []

            it "given GET /tree, when routed against the tree, then the root children are returned as json" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeApp treeRoot (request Http.GET ["tree"])
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"name\":\"Alpha\",\"path\":\"alpha\",\"kind\":\"section\""
                bodyText response `shouldInclude` "\"name\":\"Home Page\",\"path\":\"home.md\",\"kind\":\"page\""

            it "given search hits, when rendered as json, then path, title, anchor, and excerpt carry" $ do
                let hit =
                        Store.Hit
                            { Store.hitPage = "guides/a.md"
                            , Store.hitAnchor = "Failover"
                            , Store.hitSeq = 1
                            , Store.hitScore = 0.5
                            , Store.hitText = "Guide > Setup\nConfigure the \"failover\" timeouts."
                            }
                App.searchResultsJson 2 [hit]
                    `shouldBe` "{\"enabled\":true,\"pending\":2,\"results\":[{\"path\":\"guides/a.md\",\"title\":\"Guide\",\"anchor\":\"Failover\",\"excerpt\":\"Configure the \\\"failover\\\" timeouts.\"}]}"

            it "given a titled page, when read, then the html title is the frontmatter name" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeApp treeRoot (request Http.GET ["documents", "home.md"])
                bodyText response `shouldInclude` "<title>Home Page</title>"

            it "given an untitled page, when read, then the html title humanises the filename" $ do
                treeRoot <- setupTreeFixture
                writeFile (treeRoot ++ "/plain-notes.md") "no frontmatter here\n"
                response <- runTreeApp treeRoot (request Http.GET ["documents", "plain-notes.md"])
                Directory.removeFile (treeRoot ++ "/plain-notes.md")
                bodyText response `shouldInclude` "<title>Plain Notes</title>"

            it "given an unwritten page opened to edit, when seeded, then the html title is New page" $ do
                treeRoot <- setupTreeFixture
                let req = (request Http.GET ["documents", "fresh-page.md"]){Http.requestQuery = [("edit", "")]}
                response <- runTreeApp treeRoot req
                bodyText response `shouldInclude` "<title>New page</title>"

            it "given a page's history view, when rendered, then the html title is History: name" $ do
                treeRoot <- setupTreeFixture
                let req = (request Http.GET ["documents", "home.md"]){Http.requestQuery = [("history", "")]}
                response <- runTreeApp treeRoot req
                bodyText response `shouldInclude` "<title>History: Home Page</title>"

            it "given a page's standalone diff view, when rendered, then the html title is Diff: name" $ do
                treeRoot <- setupTreeFixture
                let req =
                        (request Http.GET ["documents", "home.md"])
                            { Http.requestQuery = [("diff", ""), ("from", "a"), ("to", "b")]
                            }
                response <- runTreeApp treeRoot req
                bodyText response `shouldInclude` "<title>Diff: Home Page</title>"

            it "given a page read against the tree, when rendered, then the editor embeds the navigation spine" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeApp treeRoot (request Http.GET ["documents", "alpha", "page.md"])
                bodyText response `shouldInclude` "data-tree-spine="
                bodyText response `shouldInclude` "Alpha Page"
                bodyText response `shouldInclude` "Beta"

            it "given a title, when slugified, then it is lower-cased kebab-case with runs collapsed and trimmed" $ do
                App.slugify "Network Delivery" `shouldBe` "network-delivery"
                App.slugify "  A: B & C!  " `shouldBe` "a-b-c"
                App.slugify "!!!" `shouldBe` "untitled"

            it "given POST /tree create page, when routed, then the seeded page is written and returned, and appears in the tree" $ do
                treeRoot <- setupTreeFixture
                cleanFile (treeRoot ++ "/alpha/created-page.md")
                response <- runTreeAppBody treeRoot (request Http.POST ["tree", "alpha"]) "kind=page&title=Created+Page"
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"path\":\"alpha/created-page.md\""
                bodyText response `shouldInclude` "\"editPath\":\"alpha/created-page.md\""
                bodyText response `shouldInclude` "\"kind\":\"page\""
                written <- readFile (treeRoot ++ "/alpha/created-page.md")
                written `shouldBe` "---\nname: Created Page\n---\n\n# Created Page\n"
                nodes <- App.childrenOf treeRoot "alpha"
                map App.nodeName nodes `shouldBe` ["Alpha Page", "Created Page"]
                cleanFile (treeRoot ++ "/alpha/created-page.md")

            it "given POST /tree create with no title, when routed, then it is a bad request" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeAppBody treeRoot (request Http.POST ["tree", "alpha"]) "kind=page&title="
                Http.statusCode (Http.responseStatus response) `shouldBe` 400

            it "given POST /tree ?move preview, when routed, then it returns the impact plan without writing" $ do
                treeRoot <- setupTreeFixture
                let req = (request Http.POST ["tree", "beta"]){Http.requestQuery = [("move", "")]}
                response <- runTreeAppBody treeRoot req "to=alpha&slug=beta&confirm="
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"from\":\"beta\""
                bodyText response `shouldInclude` "\"to\":\"alpha/beta\""
                bodyText response `shouldInclude` "\"applied\":false"
                stillThere <- Directory.doesFileExist (treeRoot ++ "/beta/index.md")
                stillThere `shouldBe` True

            it "given POST /tree ?move on the root, when routed, then it is refused with 409" $ do
                treeRoot <- setupTreeFixture
                let req = (request Http.POST ["tree"]){Http.requestQuery = [("move", "")]}
                response <- runTreeAppBody treeRoot req "to=alpha&confirm=true"
                Http.statusCode (Http.responseStatus response) `shouldBe` 409

            it "given POST /tree ?move preview for a page, when routed, then it dispatches to the page move" $ do
                treeRoot <- setupTreeFixture
                let req = (request Http.POST ["tree", "alpha", "page.md"]){Http.requestQuery = [("move", "")]}
                response <- runTreeAppBody treeRoot req "to=beta&confirm="
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"from\":\"alpha/page.md\""
                bodyText response `shouldInclude` "\"to\":\"beta/page.md\""
                bodyText response `shouldInclude` "\"applied\":false"
                stillThere <- Directory.doesFileExist (treeRoot ++ "/alpha/page.md")
                stillThere `shouldBe` True

            it "given POST /tree ?move confirmed, when applied, then a move record is appended to the operation log" $ do
                let appliedRoot = "build/tree-applied-move"
                    logFile = "build/tree-spec-oplog"
                removeTree appliedRoot
                cleanFile logFile
                Directory.createDirectoryIfMissing True (appliedRoot ++ "/x")
                Directory.createDirectoryIfMissing True (appliedRoot ++ "/y")
                writeFile (appliedRoot ++ "/index.md") "# Root\n"
                writeFile (appliedRoot ++ "/x/index.md") "---\nname: X\n---\n\n# X\n"
                writeFile (appliedRoot ++ "/y/index.md") "# Y\n"
                let req = (request Http.POST ["tree", "x"]){Http.requestQuery = [("move", "")]}
                response <- runTreeAppBody appliedRoot req "to=y&slug=x&confirm=true"
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                logged <- readFile logFile
                logged `shouldInclude` "\"type\":\"move\""
                logged `shouldInclude` "\"kind\":\"section\""
                logged `shouldInclude` "\"from\":\"x\""
                logged `shouldInclude` "\"to\":\"y/x\""

            it "given POST /tree ?delete on a referenced page, when routed, then it is refused with the referrer list" $ do
                appliedRoot <- setupDeleteRouteFixture
                let req = (request Http.POST ["tree", "a.md"]){Http.requestQuery = [("delete", "")]}
                response <- runTreeAppBody appliedRoot req ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 409
                bodyText response `shouldInclude` "\"refused\":true"
                bodyText response `shouldInclude` "\"page\":\"b.md\""

            it "given POST /tree ?delete on an unreferenced page, when routed, then it trashes the page and logs a delete" $ do
                appliedRoot <- setupDeleteRouteFixture
                let req = (request Http.POST ["tree", "b.md"]){Http.requestQuery = [("delete", "")]}
                response <- runTreeAppBody appliedRoot req ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"deleted\":\"b.md\""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` False
                Directory.doesFileExist "build/tree-spec-trash/0/manifest" `shouldReturn` True
                logged <- readFile "build/tree-spec-oplog"
                logged `shouldInclude` "\"type\":\"delete\""
                logged `shouldInclude` "\"from\":\"b.md\""

            it "given POST /trash/<id> after a delete, when routed, then it restores the page and logs a restore" $ do
                appliedRoot <- setupDeleteRouteFixture
                let delReq = (request Http.POST ["tree", "b.md"]){Http.requestQuery = [("delete", "")]}
                _ <- runTreeAppBody appliedRoot delReq ""
                response <- runTreeAppBody appliedRoot (request Http.POST ["trash", "0"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"restored\":\"b.md\""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` True
                logged <- readFile "build/tree-spec-oplog"
                logged `shouldInclude` "\"type\":\"restore\""

            it "given POST /undo after a move, when routed, then the move is reversed and the inverse is logged" $ do
                appliedRoot <- setupMoveUndoFixture
                let mv = (request Http.POST ["tree", "x"]){Http.requestQuery = [("move", "")]}
                _ <- runTreeAppBody appliedRoot mv "to=y&slug=x&confirm=true"
                Directory.doesDirectoryExist (appliedRoot ++ "/y/x") `shouldReturn` True
                response <- runTreeAppBody appliedRoot (request Http.POST ["undo"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"undo\":\"move\""
                Directory.doesDirectoryExist (appliedRoot ++ "/x") `shouldReturn` True
                Directory.doesDirectoryExist (appliedRoot ++ "/y/x") `shouldReturn` False

            it "given GET /trash after a delete, when routed, then the trashed entry is listed" $ do
                appliedRoot <- setupDeleteRouteFixture
                _ <- runTreeAppBody appliedRoot ((request Http.POST ["tree", "b.md"]){Http.requestQuery = [("delete", "")]}) ""
                response <- runTreeApp appliedRoot (request Http.GET ["trash"])
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"path\":\"b.md\""
                bodyText response `shouldInclude` "\"kind\":\"page\""

            it "given POST /undo after a delete, when routed, then the page is restored from trash" $ do
                appliedRoot <- setupDeleteRouteFixture
                _ <- runTreeAppBody appliedRoot ((request Http.POST ["tree", "b.md"]){Http.requestQuery = [("delete", "")]}) ""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` False
                response <- runTreeAppBody appliedRoot (request Http.POST ["undo"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"undo\":\"delete\""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` True
                logged <- readFile "build/tree-spec-oplog"
                logged `shouldInclude` "\"type\":\"restore\""

            it "given POST /undo with an empty log, when routed, then it is a 409" $ do
                _ <- setupMoveUndoFixture
                response <- runTreeAppBody "build/tree-undo-move" (request Http.POST ["undo"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 409

            it "given GET /operations after a move, when routed, then the move is listed" $ do
                appliedRoot <- setupMoveUndoFixture
                let mv = (request Http.POST ["tree", "x"]){Http.requestQuery = [("move", "")]}
                _ <- runTreeAppBody appliedRoot mv "to=y&slug=x&confirm=true"
                response <- runTreeApp appliedRoot (request Http.GET ["operations"])
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"type\":\"move\""
                bodyText response `shouldInclude` "\"from\":\"x\""
                bodyText response `shouldInclude` "\"seq\":0"

            it "given POST /undo with a seq, when routed, then that specific move is inverted" $ do
                appliedRoot <- setupMoveUndoFixture
                let mv = (request Http.POST ["tree", "x"]){Http.requestQuery = [("move", "")]}
                _ <- runTreeAppBody appliedRoot mv "to=y&slug=x&confirm=true"
                Directory.doesDirectoryExist (appliedRoot ++ "/y/x") `shouldReturn` True
                response <- runTreeAppBody appliedRoot (request Http.POST ["undo"]) "seq=0"
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"undo\":\"move\""
                Directory.doesDirectoryExist (appliedRoot ++ "/x") `shouldReturn` True
                Directory.doesDirectoryExist (appliedRoot ++ "/y/x") `shouldReturn` False

nodeTuple :: App.TreeNode -> (String, App.NodeKind, String, Bool)
nodeTuple nd =
    (App.nodeName nd, App.nodeKind nd, App.nodePath nd, App.nodeHasChildren nd)

{- | Builds (idempotently) a small document tree under @build/@ for the
navigation-tree IO and routing tests, and returns its root.
-}
setupTreeFixture :: IO FilePath
setupTreeFixture = do
    let root = "build/tree-spec"
        seed name title = "---\nname: " ++ title ++ "\n---\n\n# " ++ title ++ "\n"
    Directory.createDirectoryIfMissing True (root ++ "/alpha")
    Directory.createDirectoryIfMissing True (root ++ "/beta/sub")
    Directory.createDirectoryIfMissing True (root ++ "/empty")
    Directory.createDirectoryIfMissing True (root ++ "/meta")
    Directory.createDirectoryIfMissing True (root ++ "/assets")
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

{- | Builds a delete/restore route fixture and resets the harness log/trash dirs: a
root with two pages where @b.md@ links to @a.md@ (so deleting @a.md@ is refused and
deleting @b.md@ is allowed). Returns the fixture root.
-}
setupDeleteRouteFixture :: IO FilePath
setupDeleteRouteFixture = do
    let root = "build/tree-del-route"
    removeTree root
    cleanFile "build/tree-spec-oplog"
    removeTree "build/tree-spec-trash"
    Directory.createDirectoryIfMissing True root
    writeFile (root ++ "/index.md") "# Root\n\n- [A](./a.md)\n- [B](./b.md)\n"
    writeFile (root ++ "/a.md") "# A\n"
    writeFile (root ++ "/b.md") "# B\n\n[A](./a.md)\n"
    pure root

{- | Builds an undo-of-move fixture (section @x@ at the root and an empty destination
@y@) and resets the harness log/trash dirs. Returns the fixture root.
-}
setupMoveUndoFixture :: IO FilePath
setupMoveUndoFixture = do
    let root = "build/tree-undo-move"
    removeTree root
    cleanFile "build/tree-spec-oplog"
    removeTree "build/tree-spec-trash"
    Directory.createDirectoryIfMissing True (root ++ "/x")
    Directory.createDirectoryIfMissing True (root ++ "/y")
    writeFile (root ++ "/index.md") "# Root\n"
    writeFile (root ++ "/x/index.md") "---\nname: X\n---\n\n# X\n"
    writeFile (root ++ "/y/index.md") "# Y\n"
    pure root

{- | Runs the tree-serving routes (RFC-0026) over a request head against a real
filesystem root, returning the response.
-}
runTreeApp :: FilePath -> Http.RequestHead -> IO Http.Response
runTreeApp root head = runTreeAppBody root head ""

-- | As 'runTreeApp', with a request body (for create posts).
runTreeAppBody :: FilePath -> Http.RequestHead -> String -> IO Http.Response
runTreeAppBody root head body = do
    outcome <- Iteratee.strictEnumerator (BS.pack body) (Router.route (App.treeRoutes Nothing Nothing Nothing App.noVersioning "paper" root "build/tree-spec-oplog" "build/tree-spec-trash" "build/tree-spec-index") head) >>= Iteratee.run
    case outcome of
        Right response -> return response
        Left err -> expectFailure err

-- | Removes a file if it exists (test cleanup).
cleanFile :: FilePath -> IO ()
cleanFile f = do
    exists <- Directory.doesFileExist f
    Monad.when exists (Directory.removeFile f)

-- | Recursively removes a directory tree (test cleanup; no removeDirectoryRecursive in mhs).
removeTree :: FilePath -> IO ()
removeTree dir = do
    isDir <- Directory.doesDirectoryExist dir
    Monad.when isDir $ do
        names <- Directory.listDirectory dir
        Monad.forM_ names $ \name -> do
            let path = dir ++ "/" ++ name
            sub <- Directory.doesDirectoryExist path
            if sub then removeTree path else Monad.void (FileSystem.removeFilePath path)
        _ <- FileSystem.removeEmptyDir dir
        pure ()

request :: Http.Method -> [String] -> Http.RequestHead
request method path =
    Http.emptyRequestHead
        { Http.requestMethod = method
        , Http.requestPath = path
        }

-- | A POST carrying the @hx-request@ header, as htmx sends.
htmxPost :: [String] -> Http.RequestHead
htmxPost path =
    (request Http.POST path)
        { Http.requestHeaders = [(Http.normaliseHeaderName (BS.pack "hx-request"), BS.pack "true")]
        }

{- | Runs the test application over a request head and body, returning the
response (failing the example on a stream error).
-}
runApp :: Http.RequestHead -> String -> IO Http.Response
runApp head body = do
    outcome <- Iteratee.strictEnumerator (BS.pack body) (testApp head) >>= Iteratee.run
    case outcome of
        Right response -> return response
        Left err -> expectFailure err

{- | Drives the routes at the handler level (a parsed head in), bypassing
framing, so the tests can pass a 'RequestHead' directly. The store is in
memory, so this stays a unit test with no filesystem effects.
-}
testApp :: Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
testApp = themedApp "paper"

-- | Routes through the test store with a chosen editor theme default.
themedApp :: String -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
themedApp themeDefault =
    Router.route (App.routes themeDefault testStore)

testStore :: App.DocumentStore
testStore =
    App.DocumentStore
        { App.loadDocument = \_ -> return "# Hello from MicroHttp\n\nEdit this Markdown document."
        , App.saveDocumentContent = \_ _ -> return ()
        }

-- | Renders the editor page for a request through an app with the given theme default.
runThemedApp :: String -> Http.RequestHead -> IO Http.Response
runThemedApp themeDefault head = do
    outcome <- Iteratee.strictEnumerator (BS.pack "") (themedApp themeDefault head) >>= Iteratee.run
    case outcome of
        Right response -> return response
        Left err -> expectFailure err

expectFailure :: Stream.StreamError -> IO Http.Response
expectFailure err = do
    expect ("unexpected stream failure: " ++ show err) False
    return (Http.Response Http.okStatus [] (Http.StrictBody (BS.pack "")))

bodyText :: Http.Response -> String
bodyText response =
    case Http.responseBody response of
        Http.StrictBody body -> BS.unpack body
        Http.StreamBody _ -> "<stream>"

shouldInclude :: String -> String -> Expectation
shouldInclude actual expected =
    List.isInfixOf expected actual `shouldBe` True

shouldNotInclude :: String -> String -> Expectation
shouldNotInclude actual expected =
    List.isInfixOf expected actual `shouldBe` False
