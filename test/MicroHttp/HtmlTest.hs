module Main(main) where

import MicroHttp.Html

main :: IO ()
main = do
  assertEqual
    "given htmx custom element, when rendering, then escaped HTML is returned"
    expected
    (renderHtml todoItem)

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

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expectedValue actual =
  if expectedValue == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expectedValue ++ ", got " ++ show actual)
