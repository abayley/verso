module MicroHttp.TestAppSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Iteratee (run, strictEnumerator)
import qualified MicroHttp.TestApp as TestApp
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec = do
    describe "MicroHttp.TestApp persistence" $
        it "given valid markdown form post, when saving, then markdown is written to the document store" $ do
            outcome <-
                strictEnumerator
                    (BS.pack "markdown=%23+Saved+heading")
                    (TestApp.appWithDocumentRoot documentRoot (request POST ["documents", "home"]))
                    >>= run
            saved <- readFile documentFile
            removeFile documentFile
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            saved `shouldBe` "# Saved heading"
    describe "MicroHttp.TestApp static serving" $
        it "given an editor stylesheet request, when routing, then it is served as a streaming text/css response" $ do
            outcome <-
                strictEnumerator
                    (BS.pack "")
                    (TestApp.appWithDocumentRoot documentRoot (request GET ["static", "editor", "markdown-editor.css"]))
                    >>= run
            fmap (statusCode . responseStatus) outcome `shouldBe` Right 200
            fmap contentTypeOf outcome `shouldBe` Right (Just (BS.pack "text/css"))
            fmap isStreamBody outcome `shouldBe` Right True

contentTypeOf :: Response -> Maybe BS.ByteString
contentTypeOf response =
    lookup (normaliseHeaderName (BS.pack "Content-Type")) (responseHeaders response)

isStreamBody :: Response -> Bool
isStreamBody response =
    case responseBody response of
        StreamBody _ -> True
        StrictBody _ -> False

documentRoot :: FilePath
documentRoot =
    "build"

documentFile :: FilePath
documentFile =
    documentRoot ++ "/home.md"

request :: Method -> [String] -> RequestHead
request method path =
    RequestHead
        { requestMethod = method
        , requestPath = path
        , requestQuery = []
        , requestHeaders = []
        , requestRawPath = BS.pack "/"
        }
