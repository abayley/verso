module MicroHttp.TestAppSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import qualified MicroHttp.TestApp as TestApp
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.TestApp persistence" $
        it "given valid markdown form post, when saving, then markdown is written to the document store" $ do
            response <- TestApp.appWithDocumentRoot documentRoot (request POST ["documents", "home"] "markdown=%23+Saved+heading")
            saved <- readFile documentFile
            removeFile documentFile
            statusCode (responseStatus response) `shouldBe` 200
            saved `shouldBe` "# Saved heading"

documentRoot :: FilePath
documentRoot =
    "build"

documentFile :: FilePath
documentFile =
    documentRoot ++ "/home.md"

request :: Method -> [String] -> String -> Request
request method path body =
    Request
        { requestMethod = method
        , requestPath = path
        , requestQuery = []
        , requestHeaders = []
        , requestBody = BS.pack body
        , requestRawPath = BS.pack "/"
        }
