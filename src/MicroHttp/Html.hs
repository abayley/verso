module MicroHttp.Html (
    Html,
    attr,
    a,
    a_,
    button,
    button_,
    body,
    body_,
    bytesText,
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
    renderChunks,
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

import qualified Data.ByteString.Char8 as BS
import qualified Data.String as String
import Prelude hiding (div, head, span)

{- | A difference list of 'ByteString' chunks: O(1) append by composition, run
to a chunk list in document order (RFC-0013). Constant tag and escape fragments
are pre-packed CAFs; only dynamic text packs per render.

The difference-list representation matters in mhs: @BS.append@ memcpys into a fresh
buffer, so building output by repeated @append@ would be O(n^2). Appending chunks to a
list (O(1)) and concatenating once at the socket boundary keeps it linear. (mhs ByteString
cost model: docs/design/link-index-performance.md.)
-}
newtype Builder = Builder ([BS.ByteString] -> [BS.ByteString])

instance Semigroup Builder where
    Builder f <> Builder g = Builder (f . g)

instance Monoid Builder where
    mempty = Builder id

-- | Appends one chunk to a builder.
chunk :: BS.ByteString -> Builder
chunk bytes = Builder (bytes :)

-- | Runs a builder to its chunk list, in document order.
runBuilder :: Builder -> [BS.ByteString]
runBuilder (Builder f) = f []

newtype Html a = Html (Builder, a)

instance Functor Html where
    fmap f (Html (out, value)) = Html (out, f value)

instance Applicative Html where
    pure value = Html (mempty, value)
    Html (left, f) <*> Html (right, value) = Html (left <> right, f value)

instance Monad Html where
    return = pure
    Html (left, value) >>= f =
        case f value of
            Html (right, next) -> Html (left <> right, next)

instance String.IsString (Html ()) where
    fromString = text

{- | Renders to a 'String', identical to the pre-builder renderer for the same
input (the @HtmlSpec@ golden contract). Retained for tests and callers that
still want a 'String'; the response path uses 'renderChunks'.
-}
renderHtml :: Html a -> String
renderHtml = concatMap BS.unpack . runBuilder . htmlBuilder

{- | Renders to a list of 'ByteString' chunks coalesced into buffer-sized
segments, for streaming to the socket without a whole-page concatenation or
hundreds of per-fragment writes (RFC-0013). A page below the buffer is a single
segment.
-}
renderChunks :: Html a -> [BS.ByteString]
renderChunks = coalesce coalesceBufferSize . runBuilder . htmlBuilder

-- | The accumulated builder of a rendered document.
htmlBuilder :: Html a -> Builder
htmlBuilder (Html (out, _)) = out

-- | Coalescing segment size: many small fragments become few buffer-sized writes.
coalesceBufferSize :: Int
coalesceBufferSize = 16384

{- | Packs a chunk list into segments of at least @bufSize@ bytes, in one pass,
so the socket sees few large writes rather than one fragment per chunk.
-}
coalesce :: Int -> [BS.ByteString] -> [BS.ByteString]
coalesce bufSize = finish . foldl step ([], [], 0)
  where
    step (out, cur, len) c
        | len >= bufSize = (BS.concat (reverse cur) : out, [c], BS.length c)
        | otherwise = (out, c : cur, len + BS.length c)
    finish (out, cur, _) =
        reverse (if null cur then out else BS.concat (reverse cur) : out)

-- | Emit escaped text from a 'String', decoding via the 'String' path.
text :: String -> Html ()
text = emit . escapeText

{- | Emit text from a 'ByteString' that is already UTF-8 (e.g. a document read
straight off disk). The five HTML-significant characters are escaped at the byte
level and every other byte -- including all UTF-8 continuation bytes -- passes
through verbatim. Unlike 'text' there is no 'String' round-trip and no
encoding/decoding: the bytes flow through untouched, which is the only correct
marshalling given MicroHs decodes 'String' I/O as UTF-8 but treats
'Data.ByteString.Char8' as raw bytes.
-}
bytesText :: BS.ByteString -> Html ()
bytesText = emit . escapeBytes

-- | Emit a 'String' verbatim with no escaping; the caller vouches for its safety.
rawTrusted :: String -> Html ()
rawTrusted = emit . chunk . BS.pack

-- | A container element: opening tag, children, then closing tag.
el :: String -> [(String, String)] -> Html () -> Html ()
el name attrs children = do
    emit (openTag name attrs)
    children
    emit (closeTag name)

-- | A void element: a single self-closing-style opening tag with no children.
voidEl :: String -> [(String, String)] -> Html ()
voidEl name attrs = emit (openTag name attrs)

-- | An attribute as a (name, value) pair.
attr :: String -> String -> (String, String)
attr name value = (name, value)

-- | The @class@ attribute.
class_ :: String -> (String, String)
class_ = attr "class"

-- | The @href@ attribute.
href :: String -> (String, String)
href = attr "href"

-- | The @lang@ attribute.
lang :: String -> (String, String)
lang = attr "lang"

-- | The htmx @hx-post@ attribute.
hxPost :: String -> (String, String)
hxPost = attr "hx-post"

-- | The htmx @hx-delete@ attribute.
hxDelete :: String -> (String, String)
hxDelete = attr "hx-delete"

-- | The htmx @hx-target@ attribute.
hxTarget :: String -> (String, String)
hxTarget = attr "hx-target"

-- | The htmx @hx-swap@ attribute.
hxSwap :: String -> (String, String)
hxSwap = attr "hx-swap"

-- | A container element with a caller-supplied tag name.
custom :: String -> [(String, String)] -> Html () -> Html ()
custom = el

-- | The @\<html\>@ element.
html_ :: [(String, String)] -> Html () -> Html ()
html_ = el "html"

-- | Alias for 'html_'.
html :: [(String, String)] -> Html () -> Html ()
html = html_

-- | The @\<head\>@ element.
head_ :: [(String, String)] -> Html () -> Html ()
head_ = el "head"

-- | Alias for 'head_'.
head :: [(String, String)] -> Html () -> Html ()
head = head_

-- | The @\<body\>@ element.
body_ :: [(String, String)] -> Html () -> Html ()
body_ = el "body"

-- | Alias for 'body_'.
body :: [(String, String)] -> Html () -> Html ()
body = body_

-- | The @\<title\>@ element.
title_ :: [(String, String)] -> Html () -> Html ()
title_ = el "title"

-- | Alias for 'title_'.
title :: [(String, String)] -> Html () -> Html ()
title = title_

-- | The @\<main\>@ element.
main_ :: [(String, String)] -> Html () -> Html ()
main_ = el "main"

-- | Alias for 'main_'.
main :: [(String, String)] -> Html () -> Html ()
main = main_

-- | The @\<section\>@ element.
section_ :: [(String, String)] -> Html () -> Html ()
section_ = el "section"

-- | Alias for 'section_'.
section :: [(String, String)] -> Html () -> Html ()
section = section_

-- | The @\<header\>@ element.
header_ :: [(String, String)] -> Html () -> Html ()
header_ = el "header"

-- | Alias for 'header_'.
header :: [(String, String)] -> Html () -> Html ()
header = header_

-- | The @\<nav\>@ element.
nav_ :: [(String, String)] -> Html () -> Html ()
nav_ = el "nav"

-- | Alias for 'nav_'.
nav :: [(String, String)] -> Html () -> Html ()
nav = nav_

-- | The @\<div\>@ element.
div_ :: [(String, String)] -> Html () -> Html ()
div_ = el "div"

-- | Alias for 'div_'.
div :: [(String, String)] -> Html () -> Html ()
div = div_

-- | The @\<span\>@ element.
span_ :: [(String, String)] -> Html () -> Html ()
span_ = el "span"

-- | Alias for 'span_'.
span :: [(String, String)] -> Html () -> Html ()
span = span_

-- | The @\<h1\>@ element.
h1_ :: [(String, String)] -> Html () -> Html ()
h1_ = el "h1"

-- | Alias for 'h1_'.
h1 :: [(String, String)] -> Html () -> Html ()
h1 = h1_

-- | The @\<h2\>@ element.
h2_ :: [(String, String)] -> Html () -> Html ()
h2_ = el "h2"

-- | Alias for 'h2_'.
h2 :: [(String, String)] -> Html () -> Html ()
h2 = h2_

-- | The @\<h3\>@ element.
h3_ :: [(String, String)] -> Html () -> Html ()
h3_ = el "h3"

-- | Alias for 'h3_'.
h3 :: [(String, String)] -> Html () -> Html ()
h3 = h3_

-- | The @\<p\>@ element.
p_ :: [(String, String)] -> Html () -> Html ()
p_ = el "p"

-- | Alias for 'p_'.
p :: [(String, String)] -> Html () -> Html ()
p = p_

-- | The @\<a\>@ element.
a_ :: [(String, String)] -> Html () -> Html ()
a_ = el "a"

-- | Alias for 'a_'.
a :: [(String, String)] -> Html () -> Html ()
a = a_

-- | The @\<ul\>@ element.
ul_ :: [(String, String)] -> Html () -> Html ()
ul_ = el "ul"

-- | Alias for 'ul_'.
ul :: [(String, String)] -> Html () -> Html ()
ul = ul_

-- | The @\<ol\>@ element.
ol_ :: [(String, String)] -> Html () -> Html ()
ol_ = el "ol"

-- | Alias for 'ol_'.
ol :: [(String, String)] -> Html () -> Html ()
ol = ol_

-- | The @\<li\>@ element.
li_ :: [(String, String)] -> Html () -> Html ()
li_ = el "li"

-- | Alias for 'li_'.
li :: [(String, String)] -> Html () -> Html ()
li = li_

-- | The @\<label\>@ element.
label_ :: [(String, String)] -> Html () -> Html ()
label_ = el "label"

-- | Alias for 'label_'.
label :: [(String, String)] -> Html () -> Html ()
label = label_

-- | The @\<button\>@ element.
button_ :: [(String, String)] -> Html () -> Html ()
button_ = el "button"

-- | Alias for 'button_'.
button :: [(String, String)] -> Html () -> Html ()
button = button_

-- | The @\<form\>@ element.
form_ :: [(String, String)] -> Html () -> Html ()
form_ = el "form"

-- | Alias for 'form_'.
form :: [(String, String)] -> Html () -> Html ()
form = form_

-- | The void @\<input\>@ element.
input_ :: [(String, String)] -> Html ()
input_ = voidEl "input"

-- | Alias for 'input_'.
input :: [(String, String)] -> Html ()
input = input_

-- | The void @\<meta\>@ element.
meta_ :: [(String, String)] -> Html ()
meta_ = voidEl "meta"

-- | Alias for 'meta_'.
meta :: [(String, String)] -> Html ()
meta = meta_

-- | Lifts a builder into an 'Html' action with a unit result.
emit :: Builder -> Html ()
emit out = Html (out, ())

-- | The opening tag @\<name attrs\>@ as builder chunks.
openTag :: String -> [(String, String)] -> Builder
openTag name attrs = openBracket <> chunk (BS.pack name) <> renderAttrs attrs <> closeBracket

-- | The closing tag @\</name\>@ as builder chunks.
closeTag :: String -> Builder
closeTag name = closeOpen <> chunk (BS.pack name) <> closeBracket

-- | Renders an attribute list to builder chunks, each as @ name="value"@.
renderAttrs :: [(String, String)] -> Builder
renderAttrs = foldMap renderAttr
  where
    renderAttr (name, value) =
        attrSpace <> chunk (BS.pack name) <> attrEquals <> escapeAttr value <> attrQuote

-- | Escapes element text content for safe HTML output.
escapeText :: String -> Builder
escapeText = escapeChars

-- | Escapes an attribute value for safe HTML output.
escapeAttr :: String -> Builder
escapeAttr = escapeChars

{- | Escapes the five HTML-significant characters, coalescing runs of safe
characters into one packed chunk. Byte-identical to the per-character renderer.
-}
escapeChars :: String -> Builder
escapeChars [] = mempty
escapeChars input =
    case break isSpecial input of
        (safe, []) -> packSafe safe
        (safe, c : rest) -> packSafe safe <> replacement c <> escapeChars rest
  where
    packSafe [] = mempty
    packSafe safe = chunk (BS.pack safe)

{- | The 'ByteString' analogue of 'escapeChars': escapes the HTML-significant
characters in place, emitting safe runs as zero-copy slices. The specials are all
ASCII and UTF-8 never places an ASCII byte inside a multibyte sequence, so byte-
level escaping is correct for UTF-8 content.
-}
escapeBytes :: BS.ByteString -> Builder
escapeBytes input =
    case BS.break isSpecial input of
        (safe, rest) -> safeChunk safe <> escapeRest rest
  where
    safeChunk safe = if BS.null safe then mempty else chunk safe
    escapeRest rest = case BS.uncons rest of
        Nothing -> mempty
        Just (c, more) -> replacement c <> escapeBytes more

-- | Whether a character is one of the five HTML-significant characters.
isSpecial :: Char -> Bool
isSpecial c = c == '<' || c == '>' || c == '&' || c == '"' || c == '\''

-- | The escaped builder fragment for an HTML-significant character.
replacement :: Char -> Builder
replacement '<' = ltChunk
replacement '>' = gtChunk
replacement '&' = ampChunk
replacement '"' = quotChunk
replacement '\'' = aposChunk
replacement c = chunk (BS.pack [c])

-- Pre-packed constant fragments (shared CAFs).

-- | Pre-packed structural fragments for tags and attributes.
openBracket, closeBracket, closeOpen, attrSpace, attrEquals, attrQuote :: Builder
openBracket = chunk (BS.pack "<")
closeBracket = chunk (BS.pack ">")
closeOpen = chunk (BS.pack "</")
attrSpace = chunk (BS.pack " ")
attrEquals = chunk (BS.pack "=\"")
attrQuote = chunk (BS.pack "\"")

-- | Pre-packed escape fragments for the five HTML-significant characters.
ltChunk, gtChunk, ampChunk, quotChunk, aposChunk :: Builder
ltChunk = chunk (BS.pack "&lt;")
gtChunk = chunk (BS.pack "&gt;")
ampChunk = chunk (BS.pack "&amp;")
quotChunk = chunk (BS.pack "&quot;")
aposChunk = chunk (BS.pack "&#39;")
