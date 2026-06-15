module MicroHttp.TestAppSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Server (respondToRequestBytes)
import qualified MicroHttp.TestApp as TestApp
import System.Directory (removeFile)
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

documentRoot :: FilePath
documentRoot =
    "build"

documentFile :: FilePath
documentFile =
    documentRoot ++ "/home.md"
