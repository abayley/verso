module MicroHttp.HttpSpec(spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import Test.Hspec

spec :: Spec
spec =
  describe "MicroHttp.Http" $ do
    it "given GET token, when parsing method, then GET constructor is returned" $
      parseMethod (bs "GET") `shouldBe` Just GET
    it "given extension method token, when parsing method, then method is rejected" $
      parseMethod (bs "PROPFIND") `shouldBe` Nothing
    it "given POST token, when parsing method, then POST constructor is returned" $
      parseMethod (bs "POST") `shouldBe` Just POST
    it "given mixed-case header name, when normalising, then lower-case name is returned" $
      normaliseHeaderName (bs "Content-Type") `shouldBe` HeaderName (bs "content-type")
    it "given strict body response, when reading response body, then strict body is visible" $
      responseBody (Response okStatus [] (StrictBody (bs "hello")))
        `shouldBe` StrictBody (bs "hello")
    it "given file body response, when reading response body, then file path is visible" $
      responseBody (Response okStatus [] (FileBody "public/app.css"))
        `shouldBe` FileBody "public/app.css"

bs :: String -> BS.ByteString
bs = BS.pack
