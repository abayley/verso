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
        it "given a form value with a plus and a percent escape, when decoding bytes, then both are decoded" $
            Http.decodeFormValueBytes (bs "a+b%2Dc") `shouldBe` bs "a b-c"
        it "given empty bytes, when decoding a form value, then the result is empty" $
            Http.decodeFormValueBytes (bs "") `shouldBe` bs ""
        it "given a percent-encoded multibyte character, when decoding bytes, then its bytes survive verbatim" $
            Http.decodeFormValueBytes (bs "caf%C3%A9") `shouldBe` bs "caf\xc3\xa9"
        it "given lower-case hex digits, when decoding bytes, then the escape is decoded" $
            Http.decodeFormValueBytes (bs "%7bx%7d") `shouldBe` bs "{x}"
        it "given a trailing bare percent, when decoding bytes, then it is kept verbatim" $
            Http.decodeFormValueBytes (bs "abc%") `shouldBe` bs "abc%"
        it "given a truncated escape at the end, when decoding bytes, then it is kept verbatim" $
            Http.decodeFormValueBytes (bs "abc%a") `shouldBe` bs "abc%a"
        it "given a non-hex escape, when decoding bytes, then it is kept verbatim" $
            Http.decodeFormValueBytes (bs "a%zzb") `shouldBe` bs "a%zzb"
        it "given a mixed body, when decoding bytes, then it agrees with the string decoder" $
            Http.decodeFormValueBytes (bs mixedFormValue)
                `shouldBe` bs (Http.decodeFormValue mixedFormValue)
        it "given a document-sized value, when decoding bytes, then it decodes without exhausting the stack" $
            BS.length (Http.decodeFormValueBytes (bs (concat (replicate 30000 "word+word%0A"))))
                `shouldBe` 30000 * 10
        it "given a document-sized form body, when parsing bytes, then its field decodes without exhausting the stack" $
            map (BS.length . snd) (Http.parseFormBody (bs ("markdown=" ++ concat (replicate 30000 "word+word%0A"))))
                `shouldBe` [30000 * 10]
        it "given a form body at the megabyte body cap, when parsing bytes, then its field decodes in full" $
            map (BS.length . snd) (Http.parseFormBody (BS.append (bs "markdown=") megabyteFormValue))
                `shouldBe` [89088 * 10]
        it "given a two-field form body, when parsing bytes, then keys and values are decoded" $
            Http.parseFormBody (bs "kind=page&title=My+Page")
                `shouldBe` [(bs "kind", bs "page"), (bs "title", bs "My Page")]
        it "given an empty form body, when parsing bytes, then there are no fields" $
            Http.parseFormBody (bs "") `shouldBe` []
        it "given a field with no equals sign, when parsing bytes, then its value is empty" $
            Http.parseFormBody (bs "flag") `shouldBe` [(bs "flag", bs "")]
        it "given a value containing an encoded equals sign, when parsing bytes, then only the first splits" $
            Http.parseFormBody (bs "q=a=b") `shouldBe` [(bs "q", bs "a=b")]

bs :: String -> BS.ByteString
bs = BS.pack

{- | A form value in the shape a browser actually posts: @+@ for spaces, @%0A@
line ends, percent-encoded punctuation and multibyte characters, and malformed
escapes that must survive untouched.
-}
mixedFormValue :: String
mixedFormValue = "%23+Heading%0A%0AText+with+caf%C3%A9%2C+100%25+sure%3F%0A%zz+%+%a"

{- | An encoded value just over the 1 MiB body cap, joined from packed chunks
rather than packed from a megabyte 'String' (which would itself be too deep a
list for the fixture to be about the code under test).
-}
megabyteFormValue :: BS.ByteString
megabyteFormValue = BS.concat (replicate 87 (BS.concat (replicate 1024 (bs "word+word%0A"))))
