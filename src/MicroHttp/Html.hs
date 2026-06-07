module MicroHttp.Html (
    Html,
    attr,
    a,
    a_,
    button,
    button_,
    body,
    body_,
    class_,
    custom,
    div,
    div_,
    el,
    form_,
    h1,
    h1_,
    h2,
    h2_,
    h3,
    h3_,
    head,
    head_,
    header,
    header_,
    href,
    html,
    html_,
    hxDelete,
    hxPost,
    hxSwap,
    hxTarget,
    input,
    input_,
    label,
    label_,
    lang,
    li,
    li_,
    main,
    main_,
    meta,
    meta_,
    nav,
    nav_,
    ol,
    ol_,
    p,
    p_,
    rawTrusted,
    renderHtml,
    section,
    section_,
    span,
    span_,
    text,
    title,
    title_,
    ul,
    ul_,
    voidEl,
) where

import Data.String (IsString (..))
import Prelude hiding (div, head, span)

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

instance IsString (Html ()) where
    fromString = text

renderHtml :: Html a -> String
renderHtml (Html (out, _)) = out

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

href :: String -> (String, String)
href = attr "href"

lang :: String -> (String, String)
lang = attr "lang"

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

html_ :: [(String, String)] -> Html () -> Html ()
html_ = el "html"

html :: [(String, String)] -> Html () -> Html ()
html = html_

head_ :: [(String, String)] -> Html () -> Html ()
head_ = el "head"

head :: [(String, String)] -> Html () -> Html ()
head = head_

body_ :: [(String, String)] -> Html () -> Html ()
body_ = el "body"

body :: [(String, String)] -> Html () -> Html ()
body = body_

title_ :: [(String, String)] -> Html () -> Html ()
title_ = el "title"

title :: [(String, String)] -> Html () -> Html ()
title = title_

main_ :: [(String, String)] -> Html () -> Html ()
main_ = el "main"

main :: [(String, String)] -> Html () -> Html ()
main = main_

section_ :: [(String, String)] -> Html () -> Html ()
section_ = el "section"

section :: [(String, String)] -> Html () -> Html ()
section = section_

header_ :: [(String, String)] -> Html () -> Html ()
header_ = el "header"

header :: [(String, String)] -> Html () -> Html ()
header = header_

nav_ :: [(String, String)] -> Html () -> Html ()
nav_ = el "nav"

nav :: [(String, String)] -> Html () -> Html ()
nav = nav_

div_ :: [(String, String)] -> Html () -> Html ()
div_ = el "div"

div :: [(String, String)] -> Html () -> Html ()
div = div_

span_ :: [(String, String)] -> Html () -> Html ()
span_ = el "span"

span :: [(String, String)] -> Html () -> Html ()
span = span_

h1_ :: [(String, String)] -> Html () -> Html ()
h1_ = el "h1"

h1 :: [(String, String)] -> Html () -> Html ()
h1 = h1_

h2_ :: [(String, String)] -> Html () -> Html ()
h2_ = el "h2"

h2 :: [(String, String)] -> Html () -> Html ()
h2 = h2_

h3_ :: [(String, String)] -> Html () -> Html ()
h3_ = el "h3"

h3 :: [(String, String)] -> Html () -> Html ()
h3 = h3_

p_ :: [(String, String)] -> Html () -> Html ()
p_ = el "p"

p :: [(String, String)] -> Html () -> Html ()
p = p_

a_ :: [(String, String)] -> Html () -> Html ()
a_ = el "a"

a :: [(String, String)] -> Html () -> Html ()
a = a_

ul_ :: [(String, String)] -> Html () -> Html ()
ul_ = el "ul"

ul :: [(String, String)] -> Html () -> Html ()
ul = ul_

ol_ :: [(String, String)] -> Html () -> Html ()
ol_ = el "ol"

ol :: [(String, String)] -> Html () -> Html ()
ol = ol_

li_ :: [(String, String)] -> Html () -> Html ()
li_ = el "li"

li :: [(String, String)] -> Html () -> Html ()
li = li_

label_ :: [(String, String)] -> Html () -> Html ()
label_ = el "label"

label :: [(String, String)] -> Html () -> Html ()
label = label_

button_ :: [(String, String)] -> Html () -> Html ()
button_ = el "button"

button :: [(String, String)] -> Html () -> Html ()
button = button_

form_ :: [(String, String)] -> Html () -> Html ()
form_ = el "form"

form :: [(String, String)] -> Html () -> Html ()
form = form_

input_ :: [(String, String)] -> Html ()
input_ = voidEl "input"

input :: [(String, String)] -> Html ()
input = input_

meta_ :: [(String, String)] -> Html ()
meta_ = voidEl "meta"

meta :: [(String, String)] -> Html ()
meta = meta_

emit :: String -> Html ()
emit out = Html (out, ())

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
