module Verso.ViewSpec (spec) where

import Test.Hspec
import qualified Verso.View as View

spec :: Spec
spec =
    describe "Verso.View" $ do
        describe "jsonObject" $ do
            it "given no fields, when rendered, then it is an empty object" $
                View.jsonObject [] `shouldBe` "{}"

            it "given one field, when rendered, then the key is quoted and the value verbatim" $
                View.jsonObject [("deleted", View.jsonString "a.md")]
                    `shouldBe` "{\"deleted\":\"a.md\"}"

            it "given several fields, when rendered, then they are comma-separated in order" $
                View.jsonObject
                    [ ("page", View.jsonString "guides/a.md")
                    , ("link", View.jsonString "./b.md")
                    ]
                    `shouldBe` "{\"page\":\"guides/a.md\",\"link\":\"./b.md\"}"

            it "given a non-string value, when rendered, then it is emitted unquoted" $
                View.jsonObject [("pending", show (2 :: Int)), ("enabled", "true")]
                    `shouldBe` "{\"pending\":2,\"enabled\":true}"

            it "given a nested object as a value, when rendered, then it nests verbatim" $
                View.jsonObject [("node", View.jsonObject [("kind", View.jsonString "section")])]
                    `shouldBe` "{\"node\":{\"kind\":\"section\"}}"

            it "given a key needing escaping, when rendered, then the key is escaped too" $
                View.jsonObject [("a\"b", View.jsonString "v")]
                    `shouldBe` "{\"a\\\"b\":\"v\"}"

        describe "jsonArray" $ do
            it "given no elements, when rendered, then it is an empty array" $
                View.jsonArray [] `shouldBe` "[]"

            it "given elements, when rendered, then they are comma-separated verbatim" $
                View.jsonArray [View.jsonString "a", View.jsonString "b"]
                    `shouldBe` "[\"a\",\"b\"]"

            it "given objects, when rendered, then the array carries them in order" $
                View.jsonArray
                    [ View.jsonObject [("name", View.jsonString "one")]
                    , View.jsonObject [("name", View.jsonString "two")]
                    ]
                    `shouldBe` "[{\"name\":\"one\"},{\"name\":\"two\"}]"

        describe "jsonBool" $ do
            it "given a boolean, when rendered, then it is an unquoted json literal" $ do
                View.jsonBool True `shouldBe` "true"
                View.jsonBool False `shouldBe` "false"

            it "given a boolean field, when rendered in an object, then it stays unquoted" $
                View.jsonObject [("hasChildren", View.jsonBool True)]
                    `shouldBe` "{\"hasChildren\":true}"

        describe "jsonString" $ do
            it "given structural characters, when rendered, then they are escaped" $
                View.jsonString "a\"b\\c\nd\re\tf"
                    `shouldBe` "\"a\\\"b\\\\c\\nd\\re\\tf\""
