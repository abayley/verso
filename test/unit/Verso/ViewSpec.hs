module Verso.ViewSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.Html as Html
import Test.Hspec
import qualified Verso.View as View

spec :: Spec
spec =
    describe "Verso.View" $ do
        describe "standalone page shell" $ do
            it "given a standalone page, when rendered, then browser appearance loads before CSS without theme data" $ do
                let out = Html.renderHtml (View.versionPageShell "History: page" (pure ()))
                List.isInfixOf "src=\"/static/editor/appearance-bootstrap.js\"" out `shouldBe` True
                List.isInfixOf "data-editor-theme" out `shouldBe` False
                List.isInfixOf "role=\"menuitem\"" out `shouldBe` False
                appearsBefore "appearance-bootstrap.js" "basecoat.css" out `shouldBe` True
                appearsBefore "appearance-bootstrap.js" "markdown-editor.css" out `shouldBe` True

        describe "editor page shell" $ do
            it "given an editor page, when rendered, then browser appearance loads before CSS without theme data" $ do
                content <- Html.escapeBytes (BS.pack "# Page")
                let out =
                        Html.renderHtml
                            ( View.editorPage
                                "page.md"
                                Nothing
                                "Page"
                                content
                                False
                                False
                                False
                                []
                                []
                                "[]"
                            )
                List.isInfixOf "src=\"/static/editor/appearance-bootstrap.js\"" out `shouldBe` True
                List.isInfixOf "data-editor-theme" out `shouldBe` False
                List.isInfixOf "editor-theme" out `shouldBe` False
                appearsBefore "appearance-bootstrap.js" "basecoat.css" out `shouldBe` True
                appearsBefore "appearance-bootstrap.js" "markdown-editor.css" out `shouldBe` True

            it "given the edit view, when split into a shell around the content, then it is byte-identical to the whole page (RFC-0040)" $
                shellSplitMatchesWholePage True `shouldReturn` True
            it "given the read view, when split into a shell around the content, then it is byte-identical to the whole page (RFC-0040)" $
                shellSplitMatchesWholePage False `shouldReturn` True

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

appearsBefore :: String -> String -> String -> Bool
appearsBefore first second input =
    case (indexOf first input, indexOf second input) of
        (Just firstIndex, Just secondIndex) -> firstIndex < secondIndex
        _ -> False
  where
    indexOf needle = List.findIndex (List.isPrefixOf needle) . List.tails

{- | Whether 'View.editorPage' is byte-identical to its 'View.editorShell' split
around the escaped content, for the edit or read view (RFC-0040). Exercised with a
large document carrying every escaped byte and with the data-* attributes set, so
the shell's attribute branches are covered. The content bytes are the escaped
document as 'Html.escapedText' renders it, which is what the streamed path emits.
-}
shellSplitMatchesWholePage :: Bool -> IO Bool
shellSplitMatchesWholePage editable = do
    escaped <- Html.escapeBytes largeContent
    let contentBytes = BS.concat (Html.renderChunks (Html.escapedText escaped))
        whole = BS.concat (Html.renderChunks (View.editorPage docId mode title escaped versioned editable hasDraft attachments breadcrumbs spine))
        (before, after) = View.editorShell docId mode title versioned editable hasDraft attachments breadcrumbs spine
        split = BS.concat (Html.renderChunksRaw before) `BS.append` contentBytes `BS.append` BS.concat (Html.renderChunksRaw after)
    pure (whole == split)
  where
    docId = "sec/page.md"
    mode = Just "wysiwyg"
    title = "A <Titled> & \"quoted\" page"
    versioned = True
    hasDraft = True
    attachments = [("assets/My_Report.pdf", "My Report.pdf")]
    breadcrumbs = [View.Crumb "Section" (Just "/documents/sec/"), View.Crumb "Page" Nothing]
    spine = "[{\"path\":\"sec/page.md\"}]"

-- | A ~260KB document with every escaped byte, at and across block boundaries.
largeContent :: BS.ByteString
largeContent = BS.concat (replicate 6000 (BS.pack "line <a> & \"b\" 'c' \xc3\xa9 \xf0\x9f\x98\x80 text >here<\n"))
