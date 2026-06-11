module MicroHttp.TestAppSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Iteratee (run, strictEnumerator)
import qualified MicroHttp.TestApp as TestApp
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec =
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
