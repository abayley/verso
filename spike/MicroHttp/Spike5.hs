module MicroHttp.Spike5(main) where

import MicroHttp.Html

main :: IO ()
main = do
  assertEqual "html rendering" expected (renderHtml todoItem)
  putStrLn "spike 5 html checks passed"

todoItem :: Html ()
todoItem =
  custom "todo-item" [attr "data-id" "42", hxTarget "#todos"] $ do
    div_ [class_ "todo-title"] $
      text "A <dangerous> & useful item"
    button_
      [ hxDelete "/todos/42"
      , hxSwap "outerHTML"
      ]
      (text "Delete")

expected :: String
expected =
  "<todo-item data-id=\"42\" hx-target=\"#todos\">" ++
  "<div class=\"todo-title\">A &lt;dangerous&gt; &amp; useful item</div>" ++
  "<button hx-delete=\"/todos/42\" hx-swap=\"outerHTML\">Delete</button>" ++
  "</todo-item>"

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expectedValue actual =
  if expectedValue == actual then
    return ()
  else
    error (label ++ " expected " ++ show expectedValue ++ " but got " ++ show actual)
