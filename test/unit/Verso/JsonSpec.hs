module Verso.JsonSpec (spec) where

import Test.Hspec
import qualified Verso.Json as Json

spec :: Spec
spec =
    describe "Verso.Json" $ do
        describe "render of each variant" $ do
            it "given null, when rendered, then it is the null literal" $
                Json.render Json.JNull `shouldBe` "null"
            it "given true and false, when rendered, then they are the boolean literals" $
                map (Json.render . Json.bool) [True, False] `shouldBe` ["true", "false"]
            it "given an integer, when rendered, then it is the bare number" $
                Json.render (Json.int 42) `shouldBe` "42"
            it "given a negative integer, when rendered, then its sign is kept" $
                Json.render (Json.int (-7)) `shouldBe` "-7"
            it "given a plain string, when rendered, then it is quoted" $
                Json.render (Json.string "hello") `shouldBe` "\"hello\""
        describe "objects and arrays" $ do
            it "given an object, when rendered, then its fields are comma-separated with quoted keys" $
                Json.render (Json.object [("a", Json.int 1), ("b", Json.bool True)]) `shouldBe` "{\"a\":1,\"b\":true}"
            it "given the empty object, when rendered, then it is a pair of braces" $
                Json.render (Json.object []) `shouldBe` "{}"
            it "given an array, when rendered, then its items are comma-separated" $
                Json.render (Json.array [Json.string "x", Json.int 2]) `shouldBe` "[\"x\",2]"
            it "given the empty array, when rendered, then it is a pair of brackets" $
                Json.render (Json.array []) `shouldBe` "[]"
            it "given a nested object, when rendered, then the nesting is preserved" $
                Json.render (Json.object [("outer", Json.array [Json.object [("k", Json.string "v")]])])
                    `shouldBe` "{\"outer\":[{\"k\":\"v\"}]}"
        describe "string escaping (JSON specification)" $ do
            it "given a quote and a backslash, when rendered, then both are backslash-escaped" $
                Json.render (Json.string "a\"b\\c") `shouldBe` "\"a\\\"b\\\\c\""
            it "given the short-form control characters, when rendered, then they use their short escapes" $
                Json.render (Json.string "\b\t\n\f\r") `shouldBe` "\"\\b\\t\\n\\f\\r\""
            it "given a control character with no short form, when rendered, then it is a \\u escape" $
                Json.render (Json.string "\SOH") `shouldBe` "\"\\u0001\""
            it "given the null control character, when rendered, then it is \\u0000" $
                Json.render (Json.string "\NUL") `shouldBe` "\"\\u0000\""
            it "given the unit separator U+001F, when rendered, then it is \\u001f" $
                Json.render (Json.string "\US") `shouldBe` "\"\\u001f\""
            it "given a printable character at or above U+0020, when rendered, then it is emitted as itself" $
                Json.render (Json.string " ~") `shouldBe` "\" ~\""
            it "given every C0 control character, when rendered, then the output holds no raw byte below U+0020" $
                all (>= ' ') (Json.render (Json.string ['\NUL' .. '\US'])) `shouldBe` True
            it "given control characters among printable text, when rendered, then only the printable text survives unescaped" $
                all (>= ' ') (Json.render (Json.string "a\SOHb\USc\NULd")) `shouldBe` True
