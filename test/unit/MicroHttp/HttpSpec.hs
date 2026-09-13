module MicroHttp.HttpSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http" $ do
        it "given GET token, when parsing method, then GET constructor is returned" $
            Http.parseMethod (bs "GET") `shouldBe` Just Http.GET
        it "given extension method token, when parsing method, then method is rejected" $
            Http.parseMethod (bs "PROPFIND") `shouldBe` Nothing
        it "given POST token, when parsing method, then POST constructor is returned" $
            Http.parseMethod (bs "POST") `shouldBe` Just Http.POST
        it "given mixed-case header name, when normalising, then lower-case name is returned" $
            Http.normaliseHeaderName (bs "Content-Type") `shouldBe` Http.HeaderName (bs "content-type")
        it "given strict body response, when reading response body, then strict body is visible" $
            Http.responseBody (Http.Response Http.okStatus [] (Http.StrictBody (bs "hello")))
                `shouldBe` Http.StrictBody (bs "hello")
        it "given a streaming body response, when comparing to a strict body, then they are not equal" $
            (Http.responseBody (Http.Response Http.okStatus [] (Http.StreamBody (Iteratee.strictEnumerator (bs "hello")))) == Http.StrictBody (bs "hello"))
                `shouldBe` False
        it "given two file bodies with the same path and size, when comparing, then they are equal" $
            (Http.FileBody "build/asset.txt" 9 == Http.FileBody "build/asset.txt" 9) `shouldBe` True
        it "given two file bodies differing in size, when comparing, then they are not equal" $
            (Http.FileBody "build/asset.txt" 9 == Http.FileBody "build/asset.txt" 10) `shouldBe` False
        it "given two file bodies with different paths, when comparing, then they are not equal" $
            (Http.FileBody "build/a.txt" 1 == Http.FileBody "build/b.txt" 1) `shouldBe` False
        it "given a file body, when showing, then the path and size are shown" $
            show (Http.FileBody "build/asset.txt" 9) `shouldBe` "FileBody \"build/asset.txt\" 9"

bs :: String -> BS.ByteString
bs = BS.pack
