module MicroHttp.Spike9(main) where

import MicroHttp.Html

main :: IO ()
main = do
  assertEqual "custom element" expectedCustom (renderHtml customElement)
  assertEqual "raw trusted" "<script>trusted()</script>" (renderHtml (rawTrusted "<script>trusted()</script>"))
  putStrLn "spike 9 rendering alternative checks passed"
  putStrLn "selected: local pure monadic builder for first implementation"
  putStrLn "external candidates: xhtml/lucid require package-port checks before adoption"

customElement :: Html ()
customElement =
  custom "todo-list"
    [ hxPost "/todos"
    , attr "data-owner" "A&B"
    ]
    (input_ [attr "name" "title", attr "value" "A \"quoted\" item"])

expectedCustom :: String
expectedCustom =
  "<todo-list hx-post=\"/todos\" data-owner=\"A&amp;B\">" ++
  "<input name=\"title\" value=\"A &quot;quoted&quot; item\">" ++
  "</todo-list>"

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual then
    return ()
  else
    error (label ++ " expected " ++ show expected ++ " but got " ++ show actual)
