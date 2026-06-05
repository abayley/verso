module MicroHttp.Html
  ( Html
  , renderHtml
  , text
  , rawTrusted
  , el
  , voidEl
  , attr
  , class_
  , hxPost
  , hxDelete
  , hxTarget
  , hxSwap
  , custom
  , div_
  , button_
  , form_
  , input_
  ) where

newtype Html a = Html (String, a)

instance Functor Html where
  fmap f (Html (out, value)) = Html (out, f value)

instance Applicative Html where
  pure value = Html ("", value)
  Html (left, f) <*> Html (right, value) = Html (left ++ right, f value)

instance Monad Html where
  return = pure
  Html (left, value) >>= f =
    case f value of
      Html (right, next) -> Html (left ++ right, next)

renderHtml :: Html a -> String
renderHtml (Html (out, _)) = out

emit :: String -> Html ()
emit out = Html (out, ())

text :: String -> Html ()
text = emit . escapeText

rawTrusted :: String -> Html ()
rawTrusted = emit

el :: String -> [(String, String)] -> Html () -> Html ()
el name attrs children = do
  emit ("<" ++ name ++ renderAttrs attrs ++ ">")
  children
  emit ("</" ++ name ++ ">")

voidEl :: String -> [(String, String)] -> Html ()
voidEl name attrs = emit ("<" ++ name ++ renderAttrs attrs ++ ">")

attr :: String -> String -> (String, String)
attr name value = (name, value)

class_ :: String -> (String, String)
class_ = attr "class"

hxPost :: String -> (String, String)
hxPost = attr "hx-post"

hxDelete :: String -> (String, String)
hxDelete = attr "hx-delete"

hxTarget :: String -> (String, String)
hxTarget = attr "hx-target"

hxSwap :: String -> (String, String)
hxSwap = attr "hx-swap"

custom :: String -> [(String, String)] -> Html () -> Html ()
custom = el

div_ :: [(String, String)] -> Html () -> Html ()
div_ = el "div"

button_ :: [(String, String)] -> Html () -> Html ()
button_ = el "button"

form_ :: [(String, String)] -> Html () -> Html ()
form_ = el "form"

input_ :: [(String, String)] -> Html ()
input_ = voidEl "input"

renderAttrs :: [(String, String)] -> String
renderAttrs [] = ""
renderAttrs attrs = concatMap renderAttr attrs
  where
    renderAttr (name, value) = " " ++ name ++ "=\"" ++ escapeAttr value ++ "\""

escapeText :: String -> String
escapeText = concatMap escapeChar

escapeAttr :: String -> String
escapeAttr = concatMap escapeChar

escapeChar :: Char -> String
escapeChar '<' = "&lt;"
escapeChar '>' = "&gt;"
escapeChar '&' = "&amp;"
escapeChar '"' = "&quot;"
escapeChar '\'' = "&#39;"
escapeChar c = [c]
