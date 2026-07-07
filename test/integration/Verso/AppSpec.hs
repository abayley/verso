module Verso.AppSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Process as Process
import qualified MicroHttp.Server as Server
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.App as App
import qualified Verso.Git as Git

spec :: Spec
spec = do
    describe "Verso.App persistence" $
        it "given an ordinary form post, when saving, then markdown is persisted and it redirects to the edit page" $ do
            let body = "markdown=%23+Saved+heading"
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentRoot documentRoot)
                    (BS.pack (postRequest "/documents/home" body))
            saved <- readFile documentFile
            Directory.removeFile documentFile
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/home/edit"))
            saved `shouldBe` "# Saved heading"
    describe "Verso.App static serving" $
        it "given an editor stylesheet request, when routing, then it is served as a sized text/css file body" $ do
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentRoot documentRoot)
                    (BS.pack (getRequest "/static/editor/markdown-editor.css"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/css"))
            fmap isSizedFileBody outcome `shouldBe` Right True
    describe "Verso.App document tree" $ do
        it "given an edit request for a tree document, when routing, then the editor page is returned with its content" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Hello tree")) outcome `shouldBe` Right True
        it "given a default GET of a page, when routing, then a read-only editor shell is returned with its content" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "data-readonly")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Hello tree")) outcome `shouldBe` Right True
        it "given a default GET of a missing page, when routing, then it is a 404 (reading never seeds)" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/missing.md"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 404
        it "given a ?raw request, when routing, then the file is served verbatim as a sized text/markdown body" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md?raw"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/markdown"))
            fmap isSizedFileBody outcome `shouldBe` Right True
        it "given a document with UTF-8 content, when reading, then its bytes are served verbatim (no mojibake)" $ do
            root <- setupTreeFixture
            BS.writeFile (root ++ "/sec/utf8.md") (BS.pack "# T\n\nnbsp[\xc2\xa0] acute[\xc3\xa9] emoji[\xf0\x9f\x98\x80]\n")
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/utf8.md"))
            fmap (bodyContains (BS.pack "nbsp[\xc2\xa0]")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "acute[\xc3\xa9]")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "emoji[\xf0\x9f\x98\x80]")) outcome `shouldBe` Right True
        it "given a save with UTF-8 content, when routing, then the file is written byte-exact (no re-encode)" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=caf%C3%A9%20%E2%9C%93"))
            saved <- BS.readFile (root ++ "/sec/page.md")
            saved `shouldBe` BS.pack "caf\xc3\xa9 \xe2\x9c\x93"
        it "given a GET of /, when routing, then it redirects to /documents/" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/"))
        it "given a GET of /index.html, when routing, then it redirects to /documents/" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/index.html"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/"))
        it "given a GET of /documents/, when routing, then the tree root index.md renders read-only" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "data-readonly")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Tree Home")) outcome `shouldBe` Right True
        it "given an ?edit request for a missing page, when routing, then it still seeds a starter document" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/missing.md?edit"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
        it "given a peer asset request, when routing, then the image is served from the page's assets folder" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/assets/pixel.png"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "image/png"))
            fmap isSizedFileBody outcome `shouldBe` Right True
        it "given a save for a tree document, when routing, then the file is written and it redirects to the edit page" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Edited+tree"))
            saved <- readFile (root ++ "/sec/page.md")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/sec/page.md?edit"))
            saved `shouldBe` "# Edited tree"
        it "given a path-traversal request, when routing, then it is rejected with a 404" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/../../secret.md"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 404
        it "given a save containing raw HTML, when routing, then it is written (the tree is trusted, no guard)" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%3C%21--+note+--%3E%0A%0A%23+H"))
            saved <- readFile (root ++ "/sec/page.md")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            saved `shouldBe` "<!-- note -->\n\n# H"
        it "given an asset upload, when routing, then it is stored in the page's assets folder and a relative URL is returned" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "PNGDATA"))
            stored <- readFile (root ++ "/sec/assets/diagram.png")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram.png\"}")) outcome `shouldBe` Right True
            stored `shouldBe` "PNGDATA"
        it "given an identical re-upload, when routing, then it is de-duplicated to the same file" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SAME"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SAME"))
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram.png\"}")) outcome `shouldBe` Right True
        it "given a name collision with different content, when routing, then the upload is suffixed" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "FIRST"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SECOND"))
            suffixed <- readFile (root ++ "/sec/assets/diagram-2.png")
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram-2.png\"}")) outcome `shouldBe` Right True
            suffixed `shouldBe` "SECOND"
        it "given an upload of a disallowed type, when routing, then it is rejected with a 415" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "evil.exe" "MZ"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 415
        it "given an image upload, when routing, then it is recorded in the page's images.yaml" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "Diagram One.png" "PNGDATA"))
            recorded <- readFile (root ++ "/sec/meta/page.meta/images.yaml")
            recorded
                `shouldBe` "- local_path: assets/Diagram_One.png\n\
                           \  short_title: 'Diagram One.png'\n\
                           \  description: ''\n"
        it "given an attachment upload, when routing, then it is recorded in the page's attachments.yaml omitting id and path" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            recorded <- readFile (root ++ "/sec/meta/page.meta/attachments.yaml")
            recorded
                `shouldBe` "- name: 'My Report.pdf'\n\
                           \  local_path: assets/My_Report.pdf\n\
                           \  extension: pdf\n\
                           \  external: false\n"
        it "given an edit request after an attachment upload, when routing, then the page embeds the attachment list" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (bodyContains (BS.pack "data-attachments")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "My Report.pdf")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "assets/My_Report.pdf")) outcome `shouldBe` Right True
        it "given a save carrying image titles, when routing, then it syncs the page's images.yaml short_title" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "Diagram One.png" "PNGDATA"))
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    ( BS.pack
                        ( postRequest
                            "/documents/sec/page.md"
                            "markdown=%23+H&image_count=1&image_path_0=assets%2FDiagram_One.png&image_title_0=Edited+Caption"
                        )
                    )
            recorded <- readFile (root ++ "/sec/meta/page.meta/images.yaml")
            recorded
                `shouldBe` "- local_path: assets/Diagram_One.png\n\
                           \  short_title: 'Edited Caption'\n\
                           \  description: ''\n"
        it "given an identical re-upload, when routing, then the metadata entry is not duplicated" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            recorded <- readFile (root ++ "/sec/meta/page.meta/attachments.yaml")
            recorded
                `shouldBe` "- name: 'My Report.pdf'\n\
                           \  local_path: assets/My_Report.pdf\n\
                           \  extension: pdf\n\
                           \  external: false\n"
    describe "Verso.App draft staging (RFC-0032)" $ do
        it "given versioning on, when autosaving, then a draft is staged and the live page is unchanged" $ do
            root <- setupTreeFixture
            removeIfExists (treeDraftRoot ++ "/sec/page.md")
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Draft+edit"))
            live <- readFile (root ++ "/sec/page.md")
            drafted <- readFile (treeDraftRoot ++ "/sec/page.md")
            live `shouldBe` "# Hello tree\n\nA tree document."
            drafted `shouldBe` "# Draft edit"
        it "given a staged draft, when editing, then the editor resumes the draft over the published page" $ do
            root <- setupTreeFixture
            removeIfExists (treeDraftRoot ++ "/sec/page.md")
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Drafted+heading"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (bodyContains (BS.pack "Drafted heading")) outcome `shouldBe` Right True
    describe "Verso.App publish and discard (RFC-0032)" $ do
        it "given a staged draft, when publishing, then the page is written, committed, and the draft cleared" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Published+content"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?publish" "markdown=%23+Published+content"))
            live <- readFile (root ++ "/sec/page.md")
            stillDrafted <- Directory.doesFileExist (treeDraftRoot ++ "/sec/page.md")
            revs <- Git.logForPath root "sec/page.md"
            live `shouldBe` "# Published content"
            stillDrafted `shouldBe` False
            any ((== "anonymous") . Git.revAuthor) revs `shouldBe` True
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/sec/page.md"))
        it "given a staged draft, when discarding, then the draft is removed and the live page is unchanged" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Throwaway+draft"))
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?discard-draft" ""))
            stillDrafted <- Directory.doesFileExist (treeDraftRoot ++ "/sec/page.md")
            live <- readFile (root ++ "/sec/page.md")
            stillDrafted `shouldBe` False
            live `shouldBe` "# Hello tree\n\nA tree document."
    describe "Verso.App structural-op commits (RFC-0032)" $
        it "given a deleted page with a draft, then the deletion is committed and the draft round-trips through trash on restore" $ do
            root <- setupVersionedFixture
            let draftPath = treeDraftRoot ++ "/sec/page.md"
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Draft+before+delete"))
            draftBeforeDelete <- Directory.doesFileExist draftPath
            deleteOutcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/tree/sec/page.md?delete" ""))
            draftAfterDelete <- Directory.doesFileExist draftPath
            deleteSubject <- lastCommitSubject root
            -- the trash id comes from the delete response (its op-log seq), not assumed
            let trashId = either (const "") trashIdOf deleteOutcome
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest ("/trash/" ++ trashId) ""))
            draftAfterRestore <- Directory.doesFileExist draftPath
            draftBeforeDelete `shouldBe` True
            draftAfterDelete `shouldBe` False
            BS.isInfixOf (BS.pack "Delete sec/page.md") (BS.pack deleteSubject) `shouldBe` True
            draftAfterRestore `shouldBe` True

    describe "Verso.App revision history and rollback (RFC-0032)" $ do
        it "lists a page's revisions in the history view" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?publish" "markdown=%23+Version+one"))
            history <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (getRequest "/documents/sec/page.md?history"))
            fmap (Http.statusCode . Http.responseStatus) history `shouldBe` Right 200
            fmap (bodyContains (BS.pack "Revision history")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "anonymous")) history `shouldBe` Right True
            -- the restyled page carries the editor theme head, a per-revision checkbox, and the diff hint
            fmap (bodyContains (BS.pack "data-editor-theme")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "webawesome.css")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-pick")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-hint")) history `shouldBe` Right True
            -- the theme bootstrap resolves dark/light/system (not always light)
            fmap (bodyContains (BS.pack "prefers-color-scheme")) history `shouldBe` Right True
            -- theme/appearance controls (Web Awesome, matching the editor), scrollable table,
            -- in-page diff pane, and per-revision view links
            fmap (bodyContains (BS.pack "verso-theme-dropdown")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-scheme-group")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "markdown-editor__theme-group")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-history-scroll")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-pane")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "?at=")) history `shouldBe` Right True
        it "renders a side-by-side diff between two revisions, and a bare fragment for the diff pane" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?publish" "markdown=%23+Changed+line"))
            toRev <- gitRevParse root "HEAD"
            fromRev <- gitRevParse root "HEAD^"
            diff <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (getRequest ("/documents/sec/page.md?diff&from=" ++ fromRev ++ "&to=" ++ toRev)))
            pane <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (getRequest ("/documents/sec/page.md?diff&pane&from=" ++ fromRev ++ "&to=" ++ toRev)))
            fmap (Http.statusCode . Http.responseStatus) diff `shouldBe` Right 200
            fmap (bodyContains (BS.pack "verso-diff-side")) diff `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-add")) diff `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-del")) diff `shouldBe` Right True
            -- the pane variant is a bare fragment (no page shell) carrying the side-by-side table
            fmap (bodyContains (BS.pack "verso-diff-side")) pane `shouldBe` Right True
            fmap (bodyContains (BS.pack "<html")) pane `shouldBe` Right False
        it "views a page at a past revision, read-only, showing that revision's content" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?publish" "markdown=%23+First+version"))
            firstRev <- gitRevParse root "HEAD"
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?publish" "markdown=%23+Second+version"))
            atFirst <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (getRequest ("/documents/sec/page.md?at=" ++ firstRev)))
            fmap (Http.statusCode . Http.responseStatus) atFirst `shouldBe` Right 200
            fmap (bodyContains (BS.pack "data-readonly")) atFirst `shouldBe` Right True
            fmap (bodyContains (BS.pack "First version")) atFirst `shouldBe` Right True

        it "rolls a page back to an earlier revision as a new commit" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?publish" "markdown=%23+Version+one"))
            v1Hash <- gitRevParse root "HEAD"
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?publish" "markdown=%23+Version+two"))
            -- strict reads: GHC's lazy readFile holds the handle open until the
            -- content is consumed, and the rollback below writes the same file
            -- ("resource busy" under the coverage build; mhs reads strictly)
            liveAfterV2 <- BS.unpack <$> BS.readFile (root ++ "/sec/page.md")
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned "paper" root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?rollback" ("rev=" ++ v1Hash)))
            liveAfterRollback <- BS.unpack <$> BS.readFile (root ++ "/sec/page.md")
            rollbackSubject <- lastCommitSubject root
            liveAfterV2 `shouldBe` "# Version two"
            liveAfterRollback `shouldBe` "# Version one"
            BS.isInfixOf (BS.pack "Roll back") (BS.pack rollbackSubject) `shouldBe` True

-- | The commit hash a ref resolves to in the repository at @root@ (newline stripped).
gitRevParse :: FilePath -> String -> IO String
gitRevParse root ref = do
    res <- Process.runProcess "git" ["-C", root, "rev-parse", ref] Nothing Nothing
    return (filter (/= '\n') (BS.unpack (Process.procOut res)))

-- | The subject line of the latest git commit in the repository at @root@.
lastCommitSubject :: FilePath -> IO String
lastCommitSubject root = do
    res <- Process.runProcess "git" ["-C", root, "log", "-1", "--format=%s"] Nothing Nothing
    return (BS.unpack (Process.procOut res))

-- | Extracts the @trashId@ string from a delete response body (@{"deleted":...,"trashId":"<id>"}@).
trashIdOf :: Http.Response -> String
trashIdOf response = case Http.responseBody response of
    Http.StrictBody bytes -> takeWhile (/= '"') (afterMarker "\"trashId\":\"" (BS.unpack bytes))
    _ -> ""
  where
    afterMarker marker s = go (List.tails s)
      where
        go [] = ""
        go (t : ts) = if marker `List.isPrefixOf` t then drop (length marker) t else go ts

getRequest :: String -> String
getRequest target =
    "GET " ++ target ++ " HTTP/1.1\r\n\r\n"

postRequest :: String -> String -> String
postRequest target body =
    "POST "
        ++ target
        ++ " HTTP/1.1\r\nContent-Length: "
        ++ show (length body)
        ++ "\r\n\r\n"
        ++ body

contentTypeOf :: Http.Response -> Maybe BS.ByteString
contentTypeOf response =
    lookup (Http.normaliseHeaderName (BS.pack "Content-Type")) (Http.responseHeaders response)

locationOf :: Http.Response -> Maybe BS.ByteString
locationOf response =
    lookup (Http.normaliseHeaderName (BS.pack "Location")) (Http.responseHeaders response)

isSizedFileBody :: Http.Response -> Bool
isSizedFileBody response =
    case Http.responseBody response of
        Http.FileBody _ size -> size > 0
        _ -> False

uploadRequest :: String -> String -> String -> String
uploadRequest target filename body =
    "POST "
        ++ target
        ++ " HTTP/1.1\r\nX-Attachment-Filename: "
        ++ filename
        ++ "\r\nContent-Length: "
        ++ show (length body)
        ++ "\r\n\r\n"
        ++ body

setupTreeFixture :: IO FilePath
setupTreeFixture = do
    let root = "build/tree-fixture"
    Directory.createDirectoryIfMissing True (root ++ "/sec/assets")
    -- Clear upload artifacts a previous test may have left, so dedup/collision start from a clean folder.
    mapM_ (removeIfExists . ((root ++ "/sec/assets/") ++)) ["diagram.png", "diagram-2.png", "Diagram_One.png", "My_Report.pdf"]
    -- Clear sidecar metadata a previous test may have recorded, so the metadata assertions start clean.
    mapM_ (removeIfExists . ((root ++ "/sec/meta/page.meta/") ++)) ["attachments.yaml", "images.yaml"]
    writeFile (root ++ "/index.md") "# Tree Home\n\nWelcome to the tree."
    writeFile (root ++ "/sec/page.md") "# Hello tree\n\nA tree document."
    writeFile (root ++ "/sec/assets/pixel.png") "\137PNG\r\n\SUBpixel"
    return root

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- Directory.doesFileExist path
    Monad.when exists (Directory.removeFile path)

bodyContains :: BS.ByteString -> Http.Response -> Bool
bodyContains needle response =
    case Http.responseBody response of
        Http.StrictBody bytes -> needle `BS.isInfixOf` bytes
        _ -> False

documentRoot :: FilePath
documentRoot =
    "build"

documentFile :: FilePath
documentFile =
    documentRoot ++ "/home.md"

-- | The draft staging root for the RFC-0032 draft-staging tests.
treeDraftRoot :: FilePath
treeDraftRoot =
    "build/tree-drafts"

-- | A fresh, git-initialised tree fixture (with empty drafts) for the RFC-0032 publish tests.
setupVersionedFixture :: IO FilePath
setupVersionedFixture = do
    let root = "build/tree-versioned"
    _ <- Process.runProcess "rm" ["-rf", root] Nothing Nothing
    _ <- Process.runProcess "rm" ["-rf", treeDraftRoot] Nothing Nothing
    Directory.createDirectoryIfMissing True (root ++ "/sec")
    writeFile (root ++ "/index.md") "# Home\n"
    writeFile (root ++ "/sec/page.md") "# Hello tree\n\nA tree document."
    _ <- Git.ensureRepository root (Git.Identity "Verso Import" "verso@verso.local")
    return root
