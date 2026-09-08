module Verso.AppSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Process as Process
import qualified MicroHttp.Server as Server
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.App as App
import qualified Verso.Config as VConfig
import qualified Verso.Git as Git
import qualified Verso.OperationLog as OperationLog
import qualified Verso.Trash as Trash

spec :: Spec
spec = do
    describe "Verso.App static serving" $
        it "given an editor stylesheet request, when routing, then it is served as a sized text/css file body" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/static/editor/markdown-editor.css"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/css"))
            fmap isSizedFileBody outcome `shouldBe` Right True
    describe "Verso.App startup preparation" $ do
        it "given log and oplog paths under missing directories, when the app is built, then their parents are created" $ do
            root <- setupTreeFixture
            _ <- Process.runProcess "rm" ["-rf", "build/appspec-writable"] Nothing Nothing
            let vc = appConfig root "build/appspec-writable"
            _ <- App.appFromConfig Server.defaultSettings vc
            Directory.doesDirectoryExist "build/appspec-writable/logs" `shouldReturn` True
            Directory.doesDirectoryExist "build/appspec-writable/oplog" `shouldReturn` True
        it "given trash at startup, when its manifest later disappears, then the trash endpoint still serves the warmed entry" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-trash"
                vc = appConfig root stateRoot
                trashRoot = VConfig.trashRoot vc
                logPath = VConfig.operationLog vc
                manifestPath = trashRoot ++ "/7/manifest"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            Directory.createDirectoryIfMissing True (trashRoot ++ "/7")
            Directory.createDirectoryIfMissing True (stateRoot ++ "/oplog")
            writeFile manifestPath (Trash.renderManifest (Trash.Manifest "removed.md" "page" 7 Nothing []))
            OperationLog.appendOperation logPath (OperationLog.Operation OperationLog.OpDelete "page" (Just "removed.md") Nothing 7 "2026-08-06T10:00:00.000+1200" (Just "7"))
            application <- App.appFromConfig Server.defaultSettings vc
            Directory.removeFile manifestPath

            response <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap (bodyContains (BS.pack "\"path\":\"removed.md\"")) response `shouldBe` Right True
    describe "Verso.App document tree" $ do
        it "given an edit request for a tree document, when routing, then the editor page is returned with its content" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Hello tree")) outcome `shouldBe` Right True
        it "given a default GET of a page, when routing, then a read-only editor shell is returned with its content" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/page.md"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "data-readonly")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Hello tree")) outcome `shouldBe` Right True
        it "given a default GET of a missing page, when routing, then it is a 404 (reading never seeds)" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/missing.md"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 404
        it "given a ?raw request, when routing, then the file is served verbatim as a sized text/markdown body" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/page.md?raw"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/markdown"))
            fmap isSizedFileBody outcome `shouldBe` Right True
        it "given a document with UTF-8 content, when reading, then its bytes are served verbatim (no mojibake)" $ do
            root <- setupTreeFixture
            BS.writeFile (root ++ "/sec/utf8.md") (BS.pack "# T\n\nnbsp[\xc2\xa0] acute[\xc3\xa9] emoji[\xf0\x9f\x98\x80]\n")
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/utf8.md"))
            fmap (bodyContains (BS.pack "nbsp[\xc2\xa0]")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "acute[\xc3\xa9]")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "emoji[\xf0\x9f\x98\x80]")) outcome `shouldBe` Right True
        it "given a save with UTF-8 content, when routing, then the file is written byte-exact (no re-encode)" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=caf%C3%A9%20%E2%9C%93"))
            saved <- BS.readFile (root ++ "/sec/page.md")
            saved `shouldBe` BS.pack "caf\xc3\xa9 \xe2\x9c\x93"
        it "given a save with CRLF (and lone CR) newlines, when routing, then the file is written LF-only" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=line1%0D%0Aline2%0Dline3%0Aline4"))
            saved <- BS.readFile (root ++ "/sec/page.md")
            saved `shouldBe` BS.pack "line1\nline2\nline3\nline4"
        it "given a GET of /, when routing, then it redirects to /documents/" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/"))
        it "given a GET of /index.html, when routing, then it redirects to /documents/" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/index.html"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/"))
        it "given a GET of /documents/, when routing, then the tree root index.md renders read-only" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "data-readonly")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Tree Home")) outcome `shouldBe` Right True
        it "given an ?edit request for a missing page, when routing, then it still seeds a starter document" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/missing.md?edit"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
        it "given a peer asset request, when routing, then the image is served from the page's assets folder" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/assets/pixel.png"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "image/png"))
            fmap isSizedFileBody outcome `shouldBe` Right True
        it "given a save for a tree document, when routing, then the file is written and it redirects to the edit page" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Edited+tree"))
            saved <- FileSystem.readFileStrict (root ++ "/sec/page.md")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/sec/page.md?edit"))
            saved `shouldBe` "# Edited tree"
        it "given a path-traversal request, when routing, then it is rejected with a 404" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/../../secret.md"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 404
        it "given a save containing raw HTML, when routing, then it is written (the tree is trusted, no guard)" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%3C%21--+note+--%3E%0A%0A%23+H"))
            saved <- FileSystem.readFileStrict (root ++ "/sec/page.md")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 303
            saved `shouldBe` "<!-- note -->\n\n# H"
        it "given an asset upload, when routing, then it is stored in the page's assets folder and a relative URL is returned" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "PNGDATA"))
            stored <- FileSystem.readFileStrict (root ++ "/sec/assets/diagram.png")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram.png\"}")) outcome `shouldBe` Right True
            stored `shouldBe` "PNGDATA"
        it "given an identical re-upload, when routing, then it is de-duplicated to the same file" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SAME"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SAME"))
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram.png\"}")) outcome `shouldBe` Right True
        it "given a name collision with different content, when routing, then the upload is suffixed" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "FIRST"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SECOND"))
            suffixed <- FileSystem.readFileStrict (root ++ "/sec/assets/diagram-2.png")
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram-2.png\"}")) outcome `shouldBe` Right True
            suffixed `shouldBe` "SECOND"
        it "given an upload of a disallowed type, when routing, then it is rejected with a 415" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "evil.exe" "MZ"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 415
        it "given an image upload, when routing, then it is recorded in the page's images.yaml" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "Diagram One.png" "PNGDATA"))
            recorded <- FileSystem.readFileStrict (root ++ "/sec/meta/page.meta/images.yaml")
            recorded
                `shouldBe` "- local_path: assets/Diagram_One.png\n\
                           \  short_title: 'Diagram One.png'\n\
                           \  description: ''\n"
        it "given an attachment upload, when routing, then it is recorded in the page's attachments.yaml omitting id and path" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            recorded <- FileSystem.readFileStrict (root ++ "/sec/meta/page.meta/attachments.yaml")
            recorded
                `shouldBe` "- name: 'My Report.pdf'\n\
                           \  local_path: assets/My_Report.pdf\n\
                           \  extension: pdf\n\
                           \  external: false\n"
        it "given an edit request after an attachment upload, when routing, then the page embeds the attachment list" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (bodyContains (BS.pack "data-attachments")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "My Report.pdf")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "assets/My_Report.pdf")) outcome `shouldBe` Right True
        it "given an image-titles post, when routing, then it syncs the page's images.yaml short_title" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "Diagram One.png" "PNGDATA"))
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    ( BS.pack
                        ( postRequest
                            "/documents/sec/page.md?image-titles"
                            "image_count=1&image_path_0=assets%2FDiagram_One.png&image_title_0=Edited+Caption"
                        )
                    )
            recorded <- FileSystem.readFileStrict (root ++ "/sec/meta/page.meta/images.yaml")
            recorded
                `shouldBe` "- local_path: assets/Diagram_One.png\n\
                           \  short_title: 'Edited Caption'\n\
                           \  description: ''\n"
        it "given an identical re-upload, when routing, then the metadata entry is not duplicated" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            recorded <- FileSystem.readFileStrict (root ++ "/sec/meta/page.meta/attachments.yaml")
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
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Draft+edit"))
            live <- FileSystem.readFileStrict (root ++ "/sec/page.md")
            drafted <- FileSystem.readFileStrict (treeDraftRoot ++ "/sec/page.md")
            live `shouldBe` "# Hello tree\n\nA tree document."
            drafted `shouldBe` "# Draft edit"
        it "given a staged draft, when editing, then the editor resumes the draft over the published page" $ do
            root <- setupTreeFixture
            removeIfExists (treeDraftRoot ++ "/sec/page.md")
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Drafted+heading"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (bodyContains (BS.pack "Drafted heading")) outcome `shouldBe` Right True
    describe "Verso.App draft resource (RFC-0036)" $ do
        it "given versioning on, when a raw body is PUT to /drafts, then it is staged byte-exact and the live page is unchanged" $ do
            root <- setupTreeFixture
            removeIfExists (treeDraftRoot ++ "/sec/page.md")
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/drafts/sec/page.md" "# Draft edit\n\nliteral + and %20 stay\n"))
            live <- FileSystem.readFileStrict (root ++ "/sec/page.md")
            drafted <- BS.readFile (treeDraftRoot ++ "/sec/page.md")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 204
            live `shouldBe` "# Hello tree\n\nA tree document."
            drafted `shouldBe` BS.pack "# Draft edit\n\nliteral + and %20 stay\n"
        it "given a draft staged via PUT, when editing, then the editor resumes it over the published page" $ do
            root <- setupTreeFixture
            removeIfExists (treeDraftRoot ++ "/sec/page.md")
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/drafts/sec/page.md" "# Drafted via PUT"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (bodyContains (BS.pack "Drafted via PUT")) outcome `shouldBe` Right True
        it "given an unsafe path, when PUT to /drafts, then it is refused" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/drafts/../escape.md" "# Escape"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 404
        it "given versioning off, when PUT to /drafts, then there is no draft resource" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (rawPutRequest "/drafts/sec/page.md" "# No drafts here"))
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 404
        it "given a staged draft, when DELETE on /drafts, then it is removed and the live page is unchanged" $ do
            root <- setupTreeFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/drafts/sec/page.md" "# Throwaway"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (deleteRequest "/drafts/sec/page.md"))
            stillDrafted <- Directory.doesFileExist (treeDraftRoot ++ "/sec/page.md")
            live <- FileSystem.readFileStrict (root ++ "/sec/page.md")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 204
            stillDrafted `shouldBe` False
            live `shouldBe` "# Hello tree\n\nA tree document."
    describe "Verso.App publish and discard (RFC-0032)" $ do
        it "given a staged draft, when a raw body is PUT to the page, then it is written, committed, and the draft cleared" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/drafts/sec/page.md" "# Published content"))
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Published content"))
            live <- FileSystem.readFileStrict (root ++ "/sec/page.md")
            stillDrafted <- Directory.doesFileExist (treeDraftRoot ++ "/sec/page.md")
            revs <- Git.logForPath root "sec/page.md"
            live `shouldBe` "# Published content"
            stillDrafted `shouldBe` False
            any ((== "anonymous") . Git.revAuthor) revs `shouldBe` True
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 204
        it "given an already-published body, when the identical PUT repeats, then no new revision is recorded (idempotent)" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Same content"))
            revsAfterFirst <- Git.logForPath root "sec/page.md"
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Same content"))
            revsAfterSecond <- Git.logForPath root "sec/page.md"
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 204
            length revsAfterSecond `shouldBe` length revsAfterFirst
        it "given an unrelated tree change, when a page is published, then only that page is committed" $ do
            root <- setupVersionedFixture
            writeFile (root ++ "/index.md") "# Unpublished home change\n"
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Published page"))
            committedHome <- Git.showFileAtRevision root "HEAD" "index.md"
            workingHome <- BS.readFile (root ++ "/index.md")
            committedPage <- Git.showFileAtRevision root "HEAD" "sec/page.md"
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 204
            committedHome `shouldBe` BS.pack "# Home\n"
            workingHome `shouldBe` BS.pack "# Unpublished home change\n"
            committedPage `shouldBe` BS.pack "# Published page"
        it "given versioning off, when a raw body is PUT to the page, then the live page is written directly" $ do
            root <- setupTreeFixture
            outcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Direct write\n"))
            live <- BS.readFile (root ++ "/sec/page.md")
            fmap (Http.statusCode . Http.responseStatus) outcome `shouldBe` Right 204
            live `shouldBe` BS.pack "# Direct write\n"
    describe "Verso.App structural-op commits (RFC-0032)" $
        it "given a deleted page with a draft, then the deletion is committed and the draft round-trips through trash on restore" $ do
            root <- setupVersionedFixture
            let draftPath = treeDraftRoot ++ "/sec/page.md"
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Draft+before+delete"))
            draftBeforeDelete <- Directory.doesFileExist draftPath
            deleteOutcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (deleteRequest "/tree/sec/page.md"))
            draftAfterDelete <- Directory.doesFileExist draftPath
            deleteSubject <- lastCommitSubject root
            -- the trash id comes from the delete response (its op-log seq), not assumed
            let trashId = either (const "") trashIdOf deleteOutcome
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (postRequest ("/trash/" ++ trashId) ""))
            draftAfterRestore <- Directory.doesFileExist draftPath
            draftBeforeDelete `shouldBe` True
            draftAfterDelete `shouldBe` False
            BS.isInfixOf (BS.pack "Delete sec/page.md") (BS.pack deleteSubject) `shouldBe` True
            draftAfterRestore `shouldBe` True

    describe "Verso.App trash listing and page (RFC-0028)" $ do
        it "given an empty warm catalogue, when a page is deleted, then the trash endpoint lists it" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-delete"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            writeFile (root ++ "/sec/warm-delete.md") "# Delete me\n"
            application <- App.appFromConfig Server.defaultSettings (appConfig root stateRoot)

            _ <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/tree/sec/warm-delete.md"))
            listing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap (bodyContains (BS.pack "sec/warm-delete.md")) listing `shouldBe` Right True
        it "given an entry in the warm catalogue, when it is restored, then the trash endpoint no longer lists it" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-restore"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            writeFile (root ++ "/sec/warm-restore.md") "# Restore me\n"
            application <- App.appFromConfig Server.defaultSettings (appConfig root stateRoot)
            deleted <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/tree/sec/warm-restore.md"))
            let trashId = either (const "") trashIdOf deleted

            _ <- Server.respondToRequestBytes application (BS.pack (postRequest ("/trash/" ++ trashId) ""))
            listing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap (bodyContains (BS.pack "sec/warm-restore.md")) listing `shouldBe` Right False
        it "given an entry in the warm catalogue, when it is permanently deleted, then the trash endpoint no longer lists it" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-purge-one"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            writeFile (root ++ "/sec/warm-purge-one.md") "# Purge me\n"
            application <- App.appFromConfig Server.defaultSettings (appConfig root stateRoot)
            deleted <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/tree/sec/warm-purge-one.md"))
            let trashId = either (const "") trashIdOf deleted

            _ <- Server.respondToRequestBytes application (BS.pack (deleteRequest ("/trash/" ++ trashId)))
            listing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap (bodyContains (BS.pack "sec/warm-purge-one.md")) listing `shouldBe` Right False
        it "given entries in the warm catalogue, when trash is emptied, then the trash endpoint returns an empty list" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-empty"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            writeFile (root ++ "/sec/warm-empty-one.md") "# Empty one\n"
            writeFile (root ++ "/sec/warm-empty-two.md") "# Empty two\n"
            application <- App.appFromConfig Server.defaultSettings (appConfig root stateRoot)
            _ <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/tree/sec/warm-empty-one.md"))
            _ <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/tree/sec/warm-empty-two.md"))

            _ <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/trash"))
            listing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap bodyString listing `shouldBe` Right "[]"
        it "given an expired warm entry, when retention runs, then later trash reads stay empty" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-retention"
                vc = appConfig root stateRoot
                trashRoot = VConfig.trashRoot vc
                logPath = VConfig.operationLog vc
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            Directory.createDirectoryIfMissing True (trashRoot ++ "/3")
            Directory.createDirectoryIfMissing True (stateRoot ++ "/oplog")
            writeFile (trashRoot ++ "/3/manifest") (Trash.renderManifest (Trash.Manifest "expired.md" "page" 3 Nothing []))
            OperationLog.appendOperation logPath (OperationLog.Operation OperationLog.OpDelete "page" (Just "expired.md") Nothing 3 "2020-01-01T00:00:00.000+1200" (Just "3"))
            application <- App.appFromConfig Server.defaultSettings vc

            firstListing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))
            secondListing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap bodyString firstListing `shouldBe` Right "[]"
            fmap bodyString secondListing `shouldBe` Right "[]"
        it "given a delete in the warm catalogue, when the delete is undone, then the trash endpoint no longer lists it" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-undo-delete"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            writeFile (root ++ "/sec/warm-undo-delete.md") "# Undo delete\n"
            application <- App.appFromConfig Server.defaultSettings (appConfig root stateRoot)
            _ <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/tree/sec/warm-undo-delete.md"))

            _ <- Server.respondToRequestBytes application (BS.pack (postRequest "/undo" ""))
            listing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap (bodyContains (BS.pack "sec/warm-undo-delete.md")) listing `shouldBe` Right False
        it "given a restored entry, when the restore is undone, then the trash endpoint lists the new delete" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-undo-restore"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            writeFile (root ++ "/sec/warm-undo-restore.md") "# Undo restore\n"
            application <- App.appFromConfig Server.defaultSettings (appConfig root stateRoot)
            deleted <- Server.respondToRequestBytes application (BS.pack (deleteRequest "/tree/sec/warm-undo-restore.md"))
            let trashId = either (const "") trashIdOf deleted
            _ <- Server.respondToRequestBytes application (BS.pack (postRequest ("/trash/" ++ trashId) ""))

            _ <- Server.respondToRequestBytes application (BS.pack (postRequest "/undo" ""))
            listing <- Server.respondToRequestBytes application (BS.pack (getRequest "/trash"))

            fmap (bodyContains (BS.pack "sec/warm-undo-restore.md")) listing `shouldBe` Right True
        it "given two deletions, when listing /trash, then entries are JSON newest-first with a deletion timestamp" $ do
            root <- setupTreeFixture
            writeFile (root ++ "/sec/trash-older.md") "# Older\n\nfirst to go."
            writeFile (root ++ "/sec/trash-newer.md") "# Newer\n\nsecond to go."
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (deleteRequest "/tree/sec/trash-older.md"))
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (deleteRequest "/tree/sec/trash-newer.md"))
            listing <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/trash"))
            fmap (Http.statusCode . Http.responseStatus) listing `shouldBe` Right 200
            let body = either (const "") bodyString listing
            ("sec/trash-newer.md" `List.isInfixOf` body) `shouldBe` True
            ("sec/trash-older.md" `List.isInfixOf` body) `shouldBe` True
            -- each entry carries a non-empty deletion timestamp joined from the operation log
            ("\"ts\":\"\"" `List.isInfixOf` body) `shouldBe` False
            ("\"ts\":" `List.isInfixOf` body) `shouldBe` True
            -- newest-first: the later deletion precedes the earlier one
            orderedBefore "sec/trash-newer.md" "sec/trash-older.md" body `shouldBe` True
        it "given two deletions, when listing /trash with a limit, then only the newest entry is returned" $ do
            root <- setupTreeFixture
            let stateRoot = "build/appspec-warm-limit"
            _ <- Process.runProcess "rm" ["-rf", stateRoot] Nothing Nothing
            writeFile (root ++ "/sec/trash-limit-older.md") "# Older\n"
            writeFile (root ++ "/sec/trash-limit-newer.md") "# Newer\n"
            application <- App.appFromConfig Server.defaultSettings (appConfig root stateRoot)
            _ <-
                Server.respondToRequestBytes
                    application
                    (BS.pack (deleteRequest "/tree/sec/trash-limit-older.md"))
            _ <-
                Server.respondToRequestBytes
                    application
                    (BS.pack (deleteRequest "/tree/sec/trash-limit-newer.md"))

            listing <-
                Server.respondToRequestBytes
                    application
                    (BS.pack (getRequest "/trash?limit=1"))

            fmap (bodyContains (BS.pack "sec/trash-limit-newer.md")) listing `shouldBe` Right True
            fmap (bodyContains (BS.pack "sec/trash-limit-older.md")) listing `shouldBe` Right False
        it "given a deleted page, when viewing /trashbin, then the trash page lists it newest-first with a Restore control" $ do
            root <- setupTreeFixture
            writeFile (root ++ "/sec/trash-page.md") "# Bin me\n\ncontent."
            deleteOutcome <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (deleteRequest "/tree/sec/trash-page.md"))
            let trashId = either (const "") trashIdOf deleteOutcome
            page <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/trashbin"))
            fmap (Http.statusCode . Http.responseStatus) page `shouldBe` Right 200
            fmap (bodyContains (BS.pack "Trash")) page `shouldBe` Right True
            fmap (bodyContains (BS.pack "sec/trash-page.md")) page `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-trash")) page `shouldBe` Right True
            -- the Restore control carries the entry id + path for the client to confirm and post
            fmap (bodyContains (BS.pack "verso-trash-restore")) page `shouldBe` Right True
            fmap (bodyContains (BS.pack ("data-restore-id=\"" ++ trashId ++ "\""))) page `shouldBe` Right True
            fmap (bodyContains (BS.pack "data-restore-path=\"sec/trash-page.md\"")) page `shouldBe` Right True
            -- The standalone page delegates appearance to the browser bootstrap.
            fmap (bodyContains (BS.pack "appearance-bootstrap.js")) page `shouldBe` Right True
            fmap (bodyContains (BS.pack "data-editor-theme")) page `shouldBe` Right False
        it "given a deleted page, when viewing /trashbin, then it offers empty-trash, per-row delete-forever, and the retention notice" $ do
            root <- setupTreeFixture
            writeFile (root ++ "/sec/bin-me.md") "# Bin me\n\ncontent."
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (deleteRequest "/tree/sec/bin-me.md"))
            page <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/trashbin"))
            fmap (bodyContains (BS.pack "Items older than 90 days will be permanently deleted.")) page `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-trash-empty")) page `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-trash-delete")) page `shouldBe` Right True
            fmap (bodyContains (BS.pack "data-delete-path=\"sec/bin-me.md\"")) page `shouldBe` Right True

        it "given a Referer page, when viewing /trashbin, then the back link returns to that page" $ do
            root <- setupTreeFixture
            withReferer <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequestWithReferer "/trashbin" "http://localhost:8080/documents/sec/page.md?edit"))
            fmap (bodyContains (BS.pack "/documents/sec/page.md")) withReferer `shouldBe` Right True
            fmap (bodyContains (BS.pack "Back to sec/page.md")) withReferer `shouldBe` Right True
            -- no Referer (a direct visit): the link falls back to the wiki root
            noReferer <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/trashbin"))
            fmap (bodyContains (BS.pack "Back to the wiki")) noReferer `shouldBe` Right True
            -- an off-tree Referer is ignored: the link falls back to the wiki root
            offTree <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequestWithReferer "/trashbin" "http://evil.example/documents/../../etc/passwd"))
            fmap (bodyContains (BS.pack "Back to the wiki")) offTree `shouldBe` Right True
        it "given a Referer page, when viewing /search, then the back link returns to that page" $ do
            root <- setupTreeFixture
            withReferer <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequestWithReferer "/search" "http://localhost:8080/documents/sec/page.md"))
            fmap (bodyContains (BS.pack "Back to sec/page.md")) withReferer `shouldBe` Right True
            -- no Referer (a direct visit): the link falls back to the wiki root
            noReferer <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTree root)
                    (BS.pack (getRequest "/search"))
            fmap (bodyContains (BS.pack "Back to the wiki")) noReferer `shouldBe` Right True

    describe "Verso.App revision history and rollback (RFC-0032)" $ do
        it "given a page with several revisions, when the history view is requested, then its revisions are listed" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Version one"))
            history <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (getRequest "/documents/sec/page.md?history"))
            fmap (Http.statusCode . Http.responseStatus) history `shouldBe` Right 200
            fmap (bodyContains (BS.pack "Revision history")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "anonymous")) history `shouldBe` Right True
            -- The page carries a browser-owned appearance host, a per-revision checkbox, and the diff hint.
            fmap (bodyContains (BS.pack "appearance-bootstrap.js")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "data-editor-theme")) history `shouldBe` Right False
            fmap (bodyContains (BS.pack "verso-pick")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-hint")) history `shouldBe` Right True
            -- Haskell emits only the mount point. The deferred browser bundle owns all controls.
            fmap (bodyContains (BS.pack "verso-appearance-controls")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-theme-menu")) history `shouldBe` Right False
            fmap (bodyContains (BS.pack "verso-scheme-group")) history `shouldBe` Right False
            fmap (bodyContains (BS.pack "role=\"menuitem\"")) history `shouldBe` Right False
            fmap (bodyContains (BS.pack "verso-history-scroll")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-pane")) history `shouldBe` Right True
            fmap (bodyContains (BS.pack "?at=")) history `shouldBe` Right True
        it "given two revisions, when a diff is requested, then a side-by-side diff is rendered, and a bare fragment for the diff pane" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Changed line"))
            toRev <- gitRevParse root "HEAD"
            fromRev <- gitRevParse root "HEAD^"
            diff <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (getRequest ("/documents/sec/page.md?diff&from=" ++ fromRev ++ "&to=" ++ toRev)))
            pane <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (getRequest ("/documents/sec/page.md?diff&pane&from=" ++ fromRev ++ "&to=" ++ toRev)))
            fmap (Http.statusCode . Http.responseStatus) diff `shouldBe` Right 200
            fmap (bodyContains (BS.pack "verso-diff-side")) diff `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-add")) diff `shouldBe` Right True
            fmap (bodyContains (BS.pack "verso-diff-del")) diff `shouldBe` Right True
            -- the pane variant is a bare fragment (no page shell) carrying the side-by-side table
            fmap (bodyContains (BS.pack "verso-diff-side")) pane `shouldBe` Right True
            fmap (bodyContains (BS.pack "<html")) pane `shouldBe` Right False
        it "given a past revision, when the page is viewed at it, then that revision's content is shown read-only" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# First version"))
            firstRev <- gitRevParse root "HEAD"
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Second version"))
            atFirst <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (getRequest ("/documents/sec/page.md?at=" ++ firstRev)))
            fmap (Http.statusCode . Http.responseStatus) atFirst `shouldBe` Right 200
            fmap (bodyContains (BS.pack "data-readonly")) atFirst `shouldBe` Right True
            fmap (bodyContains (BS.pack "First version")) atFirst `shouldBe` Right True

        it "given an earlier revision, when the page is rolled back to it, then the rollback lands as a new commit" $ do
            root <- setupVersionedFixture
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Version one"))
            v1Hash <- gitRevParse root "HEAD"
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (rawPutRequest "/documents/sec/page.md" "# Version two"))
            liveAfterV2 <- FileSystem.readFileStrict (root ++ "/sec/page.md")
            _ <-
                Server.respondToRequestBytes
                    (App.appWithDocumentTreeVersioned root treeDraftRoot)
                    (BS.pack (postRequest "/documents/sec/page.md?rollback" ("rev=" ++ v1Hash)))
            liveAfterRollback <- FileSystem.readFileStrict (root ++ "/sec/page.md")
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

-- | A GET request carrying a @Referer@ header (for the trash page's back-link derivation).
getRequestWithReferer :: String -> String -> String
getRequestWithReferer target referer =
    "GET " ++ target ++ " HTTP/1.1\r\nReferer: " ++ referer ++ "\r\n\r\n"

-- | A raw-body PUT (RFC-0036): the body bytes verbatim, no form encoding.
rawPutRequest :: String -> String -> String
rawPutRequest target body =
    "PUT "
        ++ target
        ++ " HTTP/1.1\r\nContent-Type: text/markdown; charset=utf-8\r\nContent-Length: "
        ++ show (length body)
        ++ "\r\n\r\n"
        ++ body

-- | A bodyless DELETE request.
deleteRequest :: String -> String
deleteRequest target =
    "DELETE " ++ target ++ " HTTP/1.1\r\nContent-Length: 0\r\n\r\n"

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

-- | A production-wired application configuration whose writable state is isolated under one test directory.
appConfig :: FilePath -> FilePath -> VConfig.VersoConfig
appConfig root stateRoot =
    VConfig.VersoConfig
        { VConfig.documentTreeRoot = root
        , VConfig.operationLog = stateRoot ++ "/oplog/operation_log"
        , VConfig.trashRoot = stateRoot ++ "/trash"
        , VConfig.trashRetentionDays = 90
        , VConfig.linkIndex = stateRoot ++ "/linkindex"
        , VConfig.accessLog = stateRoot ++ "/logs/access.log"
        , VConfig.clientErrorLog = stateRoot ++ "/logs/client-errors.log"
        , VConfig.logMaxBytes = 1048576
        , VConfig.logKeep = 2
        , VConfig.staticMounts = []
        , VConfig.versioningEnabled = False
        , VConfig.linkIndexEnabled = False
        , VConfig.draftRoot = stateRoot ++ "/drafts"
        , VConfig.identityHeader = "X-Remote-User"
        , VConfig.identityDefault = "anonymous"
        , VConfig.identityEmailDomain = "verso.local"
        , VConfig.searchEnabled = False
        , VConfig.searchModel = ""
        , VConfig.searchVocab = ""
        , VConfig.searchIndexDir = ""
        , VConfig.searchModelId = ""
        , VConfig.searchPooling = "cls"
        , VConfig.searchMaxTokens = 384
        , VConfig.searchDims = 384
        , VConfig.searchThreads = 1
        , VConfig.searchQueryPrefix = ""
        }

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

-- | A strict response body as a 'String' (empty for non-strict bodies).
bodyString :: Http.Response -> String
bodyString response =
    case Http.responseBody response of
        Http.StrictBody bytes -> BS.unpack bytes
        _ -> ""

-- | Whether @first@ appears before @second@ in @haystack@ (both must be present).
orderedBefore :: String -> String -> String -> Bool
orderedBefore first second haystack =
    case (indexOf first haystack, indexOf second haystack) of
        (Just i, Just j) -> i < j
        _ -> False
  where
    indexOf needle hay = List.findIndex (List.isPrefixOf needle) (List.tails hay)

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
