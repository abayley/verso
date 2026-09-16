module Verso.ViewSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Utf8 as Utf8
import Test.Hspec
import qualified Verso.View as View

spec :: Spec
spec =
    describe "Verso.View" $ do
        it "given a diff line holding characters above Latin-1, when scanned into rows, then the rows carry their UTF-8 bytes (RFC-0043)" $ do
            let (st, hunkRows) = View.diffScanStep View.diffScanInit (BS.pack "@@ -1 +1 @@")
                (st', rows) = View.diffScanStep st (Utf8.encodeText " caf\233 \8212 \1046")
                out = BS.concat [hunkRows, rows, View.diffScanFlush st']
            BS.isInfixOf (Utf8.encodeText "caf\233 \8212 \1046") out `shouldBe` True
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

        describe "streamed diff" $ do
            it "given a diff, when streamed as page chrome plus scanned rows, then it equals the whole diffPage render (RFC-0040)" $
                streamedDiffMatchesWhole False `shouldBe` True
            it "given a diff, when streamed as pane chrome plus scanned rows, then it equals the whole diffBody render" $
                streamedDiffMatchesWhole True `shouldBe` True

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

{- | Whether the streamed diff (chrome halves plus rows scanned a line at a time)
is byte-identical to the whole-render 'View.diffPage'/'View.diffBody' (RFC-0040).
Exercises pairing, a surplus removal, a context flush, and an end-of-input flush.
-}
streamedDiffMatchesWhole :: Bool -> Bool
streamedDiffMatchesWhole pane =
    let lns = map BS.pack (lines diffText)
        (finalState, rowsAcc) = foldl step (View.diffScanInit, BS.empty) lns
        step (st, acc) line = let (st', b) = View.diffScanStep st line in (st', BS.append acc b)
        streamedRows = BS.append rowsAcc (View.diffScanFlush finalState)
        (before, after) =
            if pane
                then View.diffPaneHalves fromRev toRev
                else View.diffPageHalves title path fromRev toRev
        streamed = BS.concat [before, streamedRows, after]
        whole =
            BS.concat
                ( Html.renderChunks
                    (if pane then View.diffBody fromRev toRev diffText else View.diffPage title path fromRev toRev diffText)
                )
     in streamed == whole
  where
    title = "Doc"
    path = "sec/p.md"
    fromRev = "aaaaaaaaaaaa"
    toRev = "bbbbbbbbbbbb"
    diffText =
        unlines
            [ "diff --git a/p.md b/p.md"
            , "index 1111111..2222222 100644"
            , "--- a/p.md"
            , "+++ b/p.md"
            , "@@ -1,3 +1,4 @@"
            , " a context line"
            , "-removed one"
            , "-removed two"
            , "+added one"
            , " another context"
            , "+added solo"
            ]
