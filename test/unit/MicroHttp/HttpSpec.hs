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
        percentDecodeSpec

{- | The percent decoders' whole-value behaviour (RFC 3986 section 2.1). Both are
exported framework API and reached from 'Http.pathSegments' and 'Http.parseQuery',
which percent-decode and then read the result as UTF-8, so a decoded value is a
string of bytes, not of characters: @%C3%A9@ decodes to two chars, 195 and 169,
and it is 'MicroHttp.Utf8.decodeUtf8' that makes them one.
-}
percentDecodeSpec :: Spec
percentDecodeSpec = do
    it "given no escapes, when decoded, then the text passes through" $ do
        Http.decodePathSegment "plain-text_1.2" `shouldBe` "plain-text_1.2"
        Http.decodeFormValue "" `shouldBe` ""
    it "given an escape, when decoded, then it is the byte it names" $
        Http.decodePathSegment "%41%42" `shouldBe` "AB"
    it "given hex digits in either case, when decoded, then both are accepted" $
        Http.decodePathSegment "%c3%A9" `shouldBe` "\195\169"
    it "given a multibyte escape, when decoded, then it is the bytes, not the character" $
        Http.decodePathSegment "caf%C3%A9" `shouldBe` "caf\195\169"
    it "given a plus, when decoded as a path segment, then it is kept" $
        Http.decodePathSegment "a+b" `shouldBe` "a+b"
    it "given a plus, when decoded as a form value, then it is a space" $
        Http.decodeFormValue "a+b" `shouldBe` "a b"
    it "given an escaped plus, when decoded as a form value, then it stays a plus" $
        Http.decodeFormValue "a%2Bb" `shouldBe` "a+b"
    it "given a non-hex escape, when decoded, then all three bytes pass through" $
        Http.decodeFormValue "%zz%g1" `shouldBe` "%zz%g1"
    it "given a truncated escape at the end, when decoded, then it passes through" $ do
        Http.decodeFormValue "a%4" `shouldBe` "a%4"
        Http.decodeFormValue "a%" `shouldBe` "a%"
    it "given an escape naming a percent, when decoded, then the result is not rescanned" $
        Http.decodeFormValue "%2541" `shouldBe` "%41"
    it "given a bare percent before a valid escape, when decoded, then the bare percent is kept and the escape still decodes" $ do
        Http.decodeFormValue "%%41" `shouldBe` "%A"
        Http.decodeFormValue "%4%41" `shouldBe` "%4A"
        Http.decodeFormValue "%%%41" `shouldBe` "%%A"
    it "given a NUL escape, when decoded, then the NUL byte is produced" $
        Http.decodeFormValue "a%00b" `shouldBe` "a\0b"
    it "given a character above U+00FF, which is outside the bytes-as-characters contract, when decoded, then only its low byte survives" $
        -- The input comes from Char8.unpack of the request line, so it can only
        -- hold bytes; U+2014 here is out of contract and truncates to its low byte.
        Http.decodePathSegment "caf\8212" `shouldBe` "caf\20"

bs :: String -> BS.ByteString
bs = BS.pack
