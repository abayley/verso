module MicroHttp.TestAppSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Server (respondToRequestBytes)
import qualified MicroHttp.TestApp as TestApp
import System.Directory (createDirectoryIfMissing, removeFile)
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
        it "given a raw Markdown request, when routing, then the file is served as a sized text/markdown body" $ do
            root <- setupTreeFixture
            outcome <-
                respondToRequestBytes
                    (TestApp.appWithDocumentTree "paper" root)
                    (BS.pack (getRequest "/documents/sec/page.md"))
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/markdown"))
            fmap isSizedFileBody outcome `shouldBe` Right True
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

setupTreeFixture :: IO FilePath
setupTreeFixture = do
    let root = "build/tree-fixture"
    createDirectoryIfMissing True (root ++ "/sec/assets")
    writeFile (root ++ "/sec/page.md") "# Hello tree\n\nA tree document."
    writeFile (root ++ "/sec/assets/pixel.png") "\137PNG\r\n\SUBpixel"
    return root

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
