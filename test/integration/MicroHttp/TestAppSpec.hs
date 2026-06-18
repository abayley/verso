module MicroHttp.TestAppSpec (spec) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Server (respondToRequestBytes)
import qualified MicroHttp.TestApp as TestApp
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import Test.Hspec

spec :: Spec
spec = do
    describe "MicroHttp.TestApp persistence" $
        it "given an ordinary form post, when saving, then markdown is persisted and it redirects to the edit page" $ do
            let body = "markdown=%23+Saved+heading"
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentRoot documentRoot)
                    (BS.pack (postRequest "/documents/home" body))
            saved <- readFile documentFile
            removeFile documentFile
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/home/edit"))
            saved `shouldBe` "# Saved heading"
    describe "MicroHttp.TestApp static serving" $
        it "given an editor stylesheet request, when routing, then it is served as a sized text/css file body" $ do
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentRoot documentRoot)
                    (BS.pack (getRequest "/static/editor/markdown-editor.css"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/css"))
            fmap isSizedFileBody outcome `shouldBe` Right True
    describe "MicroHttp.TestApp document tree" $ do
        it "given an edit request for a tree document, when routing, then the editor page is returned with its content" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Hello tree")) outcome `shouldBe` Right True
        it "given a default GET of a page, when routing, then a read-only editor shell is returned with its content" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "data-readonly")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "Hello tree")) outcome `shouldBe` Right True
        it "given a default GET of a missing page, when routing, then it is a 404 (reading never seeds)" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/missing.md"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 404
        it "given a ?raw request, when routing, then the file is served verbatim as a sized text/markdown body" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md?raw"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/markdown"))
            fmap isSizedFileBody outcome `shouldBe` Right True
        it "given an ?edit request for a missing page, when routing, then it still seeds a starter document" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/missing.md?edit"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "markdown-editor")) outcome `shouldBe` Right True
        it "given a peer asset request, when routing, then the image is served from the page's assets folder" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/assets/pixel.png"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "image/png"))
            fmap isSizedFileBody outcome `shouldBe` Right True
        it "given a save for a tree document, when routing, then the file is written and it redirects to the edit page" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%23+Edited+tree"))
            saved <- readFile (root ++ "/sec/page.md")
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 303
            fmap locationOf outcome `shouldBe` Right (Just (BS.pack "/documents/sec/page.md?edit"))
            saved `shouldBe` "# Edited tree"
        it "given a path-traversal request, when routing, then it is rejected with a 404" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/../../secret.md"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 404
        it "given a save containing raw HTML, when routing, then it is written (the tree is trusted, no guard)" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (postRequest "/documents/sec/page.md" "markdown=%3C%21--+note+--%3E%0A%0A%23+H"))
            saved <- readFile (root ++ "/sec/page.md")
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 303
            saved `shouldBe` "<!-- note -->\n\n# H"
        it "given an asset upload, when routing, then it is stored in the page's assets folder and a relative URL is returned" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "PNGDATA"))
            stored <- readFile (root ++ "/sec/assets/diagram.png")
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram.png\"}")) outcome `shouldBe` Right True
            stored `shouldBe` "PNGDATA"
        it "given an identical re-upload, when routing, then it is de-duplicated to the same file" $ do
            root <- setupTreeFixture
            _ <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SAME"))
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SAME"))
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram.png\"}")) outcome `shouldBe` Right True
        it "given a name collision with different content, when routing, then the upload is suffixed" $ do
            root <- setupTreeFixture
            _ <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "FIRST"))
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "diagram.png" "SECOND"))
            suffixed <- readFile (root ++ "/sec/assets/diagram-2.png")
            fmap (bodyContains (BS.pack "{\"url\":\"assets/diagram-2.png\"}")) outcome `shouldBe` Right True
            suffixed `shouldBe` "SECOND"
        it "given an upload of a disallowed type, when routing, then it is rejected with a 415" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "evil.exe" "MZ"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 415
        it "given an image upload, when routing, then it is recorded in the page's images.yaml" $ do
            root <- setupTreeFixture
            _ <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "Diagram One.png" "PNGDATA"))
            recorded <- readFile (root ++ "/sec/meta/page.meta/images.yaml")
            recorded
                `shouldBe` "- local_path: assets/Diagram_One.png\n\
                           \  short_title: 'Diagram One.png'\n\
                           \  description: ''\n"
        it "given an attachment upload, when routing, then it is recorded in the page's attachments.yaml omitting id and path" $ do
            root <- setupTreeFixture
            _ <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
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
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md?edit"))
            fmap (bodyContains (BS.pack "data-attachments")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "My Report.pdf")) outcome `shouldBe` Right True
            fmap (bodyContains (BS.pack "assets/My_Report.pdf")) outcome `shouldBe` Right True
        it "given a save carrying image titles, when routing, then it syncs the page's images.yaml short_title" $ do
            root <- setupTreeFixture
            _ <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "Diagram One.png" "PNGDATA"))
            _ <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
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
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            _ <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (uploadRequest "/documents/sec/page.md?asset" "My Report.pdf" "PDFDATA"))
            recorded <- readFile (root ++ "/sec/meta/page.meta/attachments.yaml")
            recorded
                `shouldBe` "- name: 'My Report.pdf'\n\
                           \  local_path: assets/My_Report.pdf\n\
                           \  extension: pdf\n\
                           \  external: false\n"

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

contentTypeOf :: Response -> Maybe BS.ByteString
contentTypeOf response =
    lookup (normaliseHeaderName (BS.pack "Content-Type")) (responseHeaders response)

locationOf :: Response -> Maybe BS.ByteString
locationOf response =
    lookup (normaliseHeaderName (BS.pack "Location")) (responseHeaders response)

isSizedFileBody :: Response -> Bool
isSizedFileBody response =
    case responseBody response of
        FileBody _ size -> size > 0
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
    createDirectoryIfMissing True (root ++ "/sec/assets")
    -- Clear upload artifacts a previous test may have left, so dedup/collision start from a clean folder.
    mapM_ (removeIfExists . ((root ++ "/sec/assets/") ++)) ["diagram.png", "diagram-2.png", "Diagram_One.png", "My_Report.pdf"]
    -- Clear sidecar metadata a previous test may have recorded, so the metadata assertions start clean.
    mapM_ (removeIfExists . ((root ++ "/sec/meta/page.meta/") ++)) ["attachments.yaml", "images.yaml"]
    writeFile (root ++ "/sec/page.md") "# Hello tree\n\nA tree document."
    writeFile (root ++ "/sec/assets/pixel.png") "\137PNG\r\n\SUBpixel"
    return root

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- doesFileExist path
    when exists (removeFile path)

bodyContains :: BS.ByteString -> Response -> Bool
bodyContains needle response =
    case responseBody response of
        StrictBody bytes -> needle `BS.isInfixOf` bytes
        _ -> False

documentRoot :: FilePath
documentRoot =
    "build"

documentFile :: FilePath
documentFile =
    documentRoot ++ "/home.md"
