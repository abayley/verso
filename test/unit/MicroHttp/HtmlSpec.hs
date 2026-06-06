module MicroHttp.HtmlSpec(spec) where

import MicroHttp.Html
import Test.Hspec

spec :: Spec
spec =
  describe "MicroHttp.Html" $
    it "given htmx custom element, when rendering, then escaped HTML is returned" $
      renderHtml todoItem `shouldBe` expected

todoItem :: Html ()
todoItem =
  custom "todo-item" [attr "data-id" "42", hxTarget "#todos"] $ do
    div_ [class_ "todo-title"] $
      text "A <dangerous> & useful item"
    input_ [attr "value" "quoted \"value\""]
    rawTrusted "<span data-safe=\"true\"></span>"
    button_
      [ hxDelete "/todos/42"
      , hxSwap "outerHTML"
      ]
      (text "Delete")

expected :: String
expected =
  "<todo-item data-id=\"42\" hx-target=\"#todos\">" ++
  "<div class=\"todo-title\">A &lt;dangerous&gt; &amp; useful item</div>" ++
  "<input value=\"quoted &quot;value&quot;\">" ++
  "<span data-safe=\"true\"></span>" ++
  "<button hx-delete=\"/todos/42\" hx-swap=\"outerHTML\">Delete</button>" ++
  "</todo-item>"
