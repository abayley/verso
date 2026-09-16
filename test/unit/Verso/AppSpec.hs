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
import qualified TestSupport.ResponseBody as ResponseBody
import qualified Verso.App as App
import qualified Verso.Json as Json
import qualified Verso.OperationLog as OperationLog

spec :: Spec
spec =
    describe "Verso.App" $ do
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
                Json.render (App.treeChildrenJson [App.TreeNode "Alpha" "alpha" App.Section True])
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
                Json.render (App.searchResultsJson 2 [hit])
                    `shouldBe` "{\"enabled\":true,\"pending\":2,\"results\":[{\"path\":\"guides/a.md\",\"title\":\"Guide\",\"anchor\":\"Failover\",\"excerpt\":\"Configure the \\\"failover\\\" timeouts.\"}]}"

            it "given the search page, when rendered, then its controls carry basecoat chrome classes" $ do
                treeRoot <- setupTreeFixture
                response <- runTreeApp treeRoot (request Http.GET ["search"])
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "class=\"input\""
                -- Instant search (search-page.ts): a chrome icon clear button, no submit button.
                bodyText response `shouldInclude` "class=\"btn verso-search-clear\" data-variant=\"ghost\" data-size=\"icon-sm\""
                bodyText response `shouldInclude` "aria-label=\"Clear search\""
                ("type=\"submit\"" `List.isInfixOf` bodyText response) `shouldBe` False

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
                written <- FileSystem.readFileStrict (treeRoot ++ "/alpha/created-page.md")
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
                logged <- FileSystem.readFileStrict logFile
                logged `shouldInclude` "\"type\":\"move\""
                logged `shouldInclude` "\"kind\":\"section\""
                logged `shouldInclude` "\"from\":\"x\""
                logged `shouldInclude` "\"to\":\"y/x\""

            it "given DELETE /tree on a referenced page, when routed, then it is refused with the referrer list" $ do
                appliedRoot <- setupDeleteRouteFixture
                let req = request Http.DELETE ["tree", "a.md"]
                response <- runTreeAppBody appliedRoot req ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 409
                bodyText response `shouldInclude` "\"refused\":true"
                bodyText response `shouldInclude` "\"page\":\"b.md\""

            it "given DELETE /tree on an unreferenced page, when routed, then it trashes the page and logs a delete" $ do
                appliedRoot <- setupDeleteRouteFixture
                let req = request Http.DELETE ["tree", "b.md"]
                response <- runTreeAppBody appliedRoot req ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"deleted\":\"b.md\""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` False
                Directory.doesFileExist "build/tree-spec-trash/0/manifest" `shouldReturn` True
                logged <- FileSystem.readFileStrict "build/tree-spec-oplog"
                logged `shouldInclude` "\"type\":\"delete\""
                logged `shouldInclude` "\"from\":\"b.md\""

            it "given POST /trash/<id> after a delete, when routed, then it restores the page and logs a restore" $ do
                appliedRoot <- setupDeleteRouteFixture
                let delReq = request Http.DELETE ["tree", "b.md"]
                _ <- runTreeAppBody appliedRoot delReq ""
                response <- runTreeAppBody appliedRoot (request Http.POST ["trash", "0"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"restored\":\"b.md\""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` True
                logged <- FileSystem.readFileStrict "build/tree-spec-oplog"
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
                _ <- runTreeAppBody appliedRoot (request Http.DELETE ["tree", "b.md"]) ""
                response <- runTreeApp appliedRoot (request Http.GET ["trash"])
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"path\":\"b.md\""
                bodyText response `shouldInclude` "\"kind\":\"page\""

            it "given POST /undo after a delete, when routed, then the page is restored from trash" $ do
                appliedRoot <- setupDeleteRouteFixture
                _ <- runTreeAppBody appliedRoot (request Http.DELETE ["tree", "b.md"]) ""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` False
                response <- runTreeAppBody appliedRoot (request Http.POST ["undo"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"undo\":\"delete\""
                Directory.doesFileExist (appliedRoot ++ "/b.md") `shouldReturn` True
                logged <- FileSystem.readFileStrict "build/tree-spec-oplog"
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

            it "given mixed operations, when recent moves are requested with a limit, then only the newest matching move is returned" $ do
                appliedRoot <- setupMoveUndoFixture
                let firstMove = (request Http.POST ["tree", "x"]){Http.requestQuery = [("move", "")]}
                _ <- runTreeAppBody appliedRoot firstMove "to=y&slug=x&confirm=true"
                OperationLog.appendOperation
                    "build/tree-spec-oplog"
                    (OperationLog.Operation OperationLog.OpDelete "page" (Just "old.md") Nothing 1 "2026-08-06T10:01:00.000+1200" (Just "1"))
                OperationLog.appendOperation
                    "build/tree-spec-oplog"
                    (OperationLog.Operation OperationLog.OpMove "page" (Just "new.md") (Just "latest.md") 2 "2026-08-06T10:02:00.000+1200" Nothing)
                let recentMoves =
                        (request Http.GET ["operations"])
                            { Http.requestQuery = [("type", "move"), ("limit", "1")]
                            }

                response <- runTreeApp appliedRoot recentMoves

                bodyText response `shouldInclude` "\"seq\":2"
                bodyText response `shouldNotInclude` "\"seq\":1"
                bodyText response `shouldNotInclude` "\"seq\":0"

            it "given DELETE /trash/<id>, when routed, then the entry is permanently removed" $ do
                appliedRoot <- setupDeleteRouteFixture
                deleteOutcome <- runTreeAppBody appliedRoot (request Http.DELETE ["tree", "b.md"]) ""
                Http.statusCode (Http.responseStatus deleteOutcome) `shouldBe` 200
                Directory.doesFileExist "build/tree-spec-trash/0/manifest" `shouldReturn` True
                response <- runTreeAppBody appliedRoot (request Http.DELETE ["trash", "0"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"purged\":\"0\""
                Directory.doesFileExist "build/tree-spec-trash/0/manifest" `shouldReturn` False
                -- the purged entry can no longer be restored
                restoreResponse <- runTreeAppBody appliedRoot (request Http.POST ["trash", "0"]) ""
                Http.statusCode (Http.responseStatus restoreResponse) `shouldBe` 409

            it "given DELETE /trash, when routed, then every entry is permanently removed" $ do
                appliedRoot <- setupDeleteRouteFixture
                _ <- runTreeAppBody appliedRoot (request Http.DELETE ["tree", "b.md"]) ""
                response <- runTreeAppBody appliedRoot (request Http.DELETE ["trash"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "\"emptied\":1"
                Directory.doesFileExist "build/tree-spec-trash/0/manifest" `shouldReturn` False
                listing <- runTreeApp appliedRoot (request Http.GET ["trash"])
                bodyText listing `shouldBe` "[]"

            it "given an entry older than the retention period, when the trash is listed, then it is purged" $ do
                appliedRoot <- setupDeleteRouteFixture
                _ <- runTreeAppBody appliedRoot (request Http.DELETE ["tree", "b.md"]) ""
                -- age the delete's log record past the 90-day default retention
                logged <- FileSystem.readFileStrict "build/tree-spec-oplog"
                null logged `shouldBe` False
                let aged = replaceTsWith "2020-01-01T00:00:00.000+1200" logged
                writeFile "build/tree-spec-oplog" aged
                listing <- runTreeApp appliedRoot (request Http.GET ["trash"])
                bodyText listing `shouldBe` "[]"
                Directory.doesFileExist "build/tree-spec-trash/0/manifest" `shouldReturn` False

            it "given a fresh entry, when the trash is listed, then it survives the retention sweep" $ do
                appliedRoot <- setupDeleteRouteFixture
                _ <- runTreeAppBody appliedRoot (request Http.DELETE ["tree", "b.md"]) ""
                listing <- runTreeApp appliedRoot (request Http.GET ["trash"])
                bodyText listing `shouldInclude` "\"path\":\"b.md\""
                Directory.doesFileExist "build/tree-spec-trash/0/manifest" `shouldReturn` True

            it "given GET /undo after a move, when routed, then the undo page lists it with an undo control" $ do
                appliedRoot <- setupMoveUndoFixture
                let mv = (request Http.POST ["tree", "x"]){Http.requestQuery = [("move", "")]}
                _ <- runTreeAppBody appliedRoot mv "to=y&slug=x&confirm=true"
                response <- runTreeApp appliedRoot (request Http.GET ["undo"])
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "Undo"
                bodyText response `shouldInclude` "verso-undo-apply"
                bodyText response `shouldInclude` "data-undo-seq=\"0\""
                bodyText response `shouldInclude` "data-undo-from=\"x\""
                bodyText response `shouldInclude` "data-undo-to=\"y/x\""

            it "given GET /undo with an empty log, when routed, then the undo page shows the empty state" $ do
                appliedRoot <- setupMoveUndoFixture
                response <- runTreeApp appliedRoot (request Http.GET ["undo"])
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldInclude` "No moves to undo."

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
    outcome <- Iteratee.strictEnumerator (BS.pack body) (Router.route (App.treeRoutes Nothing Nothing Nothing App.noVersioning root "build/tree-spec-oplog" "build/tree-spec-trash" 90 "build/tree-spec-index") head) >>= Iteratee.run
    case outcome of
        Right response -> ResponseBody.materialiseBody response
        Left err -> expectFailure err

-- | Replaces every @"ts":"..."@ value in an operation-log text (ages entries for retention tests).
replaceTsWith :: String -> String -> String
replaceTsWith newTs = go
  where
    marker = "\"ts\":\""
    go [] = []
    go s
        | marker `List.isPrefixOf` s =
            marker ++ newTs ++ "\"" ++ go (drop 1 (dropWhile (/= '"') (drop (length marker) s)))
        | otherwise = head s : go (tail s)

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

-- | Fails the example on a stream error, returning a placeholder response.
expectFailure :: Stream.StreamError -> IO Http.Response
expectFailure err = do
    expect ("unexpected stream failure: " ++ show err) False
    return (Http.Response Http.okStatus [] (Http.StrictBody (BS.pack "")))

bodyText :: Http.Response -> String
bodyText response =
    case Http.responseBody response of
        Http.StrictBody body -> BS.unpack body
        Http.StreamBody _ -> "<stream>"
        Http.SizedStreamBody _ _ -> "<stream>"
        Http.FileBody _ _ -> "<file>"

shouldInclude :: String -> String -> Expectation
shouldInclude actual expected =
    List.isInfixOf expected actual `shouldBe` True

shouldNotInclude :: String -> String -> Expectation
shouldNotInclude actual expected =
    List.isInfixOf expected actual `shouldBe` False
