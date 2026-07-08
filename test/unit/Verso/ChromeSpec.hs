module Verso.ChromeSpec (spec) where

import qualified Data.List as List
import qualified MicroHttp.Html as Html
import Test.Hspec
import qualified Verso.Chrome as Chrome

spec :: Spec
spec =
    describe "Verso.Chrome" $ do
        describe "chromeButton" $ do
            it "given a quiet control, when rendered, then it is a ghost small basecoat button" $ do
                let out = Html.renderHtml (Chrome.chromeButton Chrome.QuietControl [] (Html.text "Edit"))
                out `shouldInclude` "class=\"btn\""
                out `shouldInclude` "data-variant=\"ghost\""
                out `shouldInclude` "data-size=\"sm\""
                out `shouldInclude` "type=\"button\""
                out `shouldInclude` ">Edit</button>"
            it "given a primary action, when rendered, then it is the default variant" $ do
                let out = Html.renderHtml (Chrome.chromeButton Chrome.PrimaryAction [] (Html.text "Publish"))
                out `shouldInclude` "class=\"btn\""
                out `shouldNotInclude` "data-variant"
            it "given an outline control, when rendered, then it carries the outline variant" $ do
                let out = Html.renderHtml (Chrome.chromeButton Chrome.OutlineControl [] (Html.text "Cancel"))
                out `shouldInclude` "data-variant=\"outline\""
            it "given an icon control, when rendered, then it is a square icon button" $ do
                let out = Html.renderHtml (Chrome.chromeButton Chrome.IconControl [] (Chrome.chromeIcon "trash"))
                out `shouldInclude` "data-variant=\"ghost\""
                out `shouldInclude` "data-size=\"icon-sm\""
            it "given extra attributes, when rendered, then they are preserved" $ do
                let out = Html.renderHtml (Chrome.chromeButton Chrome.QuietControl [Html.attr "id" "x"] (Html.text "y"))
                out `shouldInclude` "id=\"x\""
        describe "chromeSubmitButton" $
            it "given a primary submit, when rendered, then the type is submit" $ do
                let out = Html.renderHtml (Chrome.chromeSubmitButton Chrome.PrimaryAction [] (Html.text "Restore"))
                out `shouldInclude` "type=\"submit\""
        describe "chromeIcon" $
            it "given an icon name, when rendered, then it references the sprite symbol" $ do
                let out = Html.renderHtml (Chrome.chromeIcon "bold")
                out `shouldInclude` "<svg class=\"chrome-icon\""
                out `shouldInclude` "<use href=\"/static/editor/icons.svg#i-bold\">"
        describe "tooltipAttrs" $ do
            it "given a label, when rendered on a button, then the tooltip attribute is present" $ do
                let out = Html.renderHtml (Chrome.chromeButton Chrome.QuietControl (Chrome.tooltipAttrs "Bold") (Html.text "B"))
                out `shouldInclude` "data-tooltip=\"Bold\""
            it "given an edge placement, when rendered, then side and align are explicit" $ do
                let out = Html.renderHtml (Chrome.chromeButton Chrome.QuietControl (Chrome.tooltipAttrsAt "Dark" "bottom" "end") (Html.text "D"))
                out `shouldInclude` "data-tooltip=\"Dark\""
                out `shouldInclude` "data-side=\"bottom\""
                out `shouldInclude` "data-align=\"end\""
        describe "chromeDropdown" $ do
            it "given items, when rendered, then the basecoat wiring is complete" $ do
                let out = Html.renderHtml (Chrome.chromeDropdown "theme-menu" Chrome.QuietControl (Html.text "Shadcn") [("shadcn", "Shadcn"), ("studio", "Studio")])
                out `shouldInclude` "class=\"dropdown-menu\" id=\"theme-menu\""
                out `shouldInclude` "id=\"theme-menu-trigger\""
                out `shouldInclude` "aria-haspopup=\"menu\""
                out `shouldInclude` "aria-controls=\"theme-menu-menu\""
                out `shouldInclude` "aria-expanded=\"false\""
                out `shouldInclude` "id=\"theme-menu-popover\""
                out `shouldInclude` "data-popover"
                out `shouldInclude` "aria-hidden=\"true\""
                out `shouldInclude` "role=\"menu\""
                out `shouldInclude` "id=\"theme-menu-menu\""
                out `shouldInclude` "aria-labelledby=\"theme-menu-trigger\""
                out `shouldInclude` "role=\"menuitem\""
                out `shouldInclude` "data-value=\"studio\""
                out `shouldInclude` ">Studio</button>"
            it "given a menu item, when rendered, then it is a real button (keyboard activation)" $ do
                let out = Html.renderHtml (Chrome.chromeDropdown "m" Chrome.QuietControl (Html.text "t") [("a", "A")])
                out `shouldInclude` "<button type=\"button\" role=\"menuitem\""
        describe "chromeTabs" $
            it "given tabs with one selected, when rendered, then the tablist wiring is complete" $ do
                let out = Html.renderHtml (Chrome.chromeTabs "mode-tabs" [("visual", "Visual", True), ("markdown", "Markdown", False)])
                out `shouldInclude` "class=\"tabs\""
                out `shouldInclude` "role=\"tablist\""
                out `shouldInclude` "data-variant=\"line\""
                out `shouldInclude` "role=\"tab\""
                out `shouldInclude` "aria-selected=\"true\""
                out `shouldInclude` "aria-selected=\"false\""
                out `shouldInclude` "data-value=\"markdown\""
                out `shouldInclude` ">Visual</button>"

shouldInclude :: String -> String -> Expectation
shouldInclude actual expected =
    List.isInfixOf expected actual `shouldBe` True

shouldNotInclude :: String -> String -> Expectation
shouldNotInclude actual expected =
    List.isInfixOf expected actual `shouldBe` False
