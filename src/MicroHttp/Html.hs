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

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.String (IsString (..))
import Prelude hiding (div, head, span)

{- | A difference list of 'ByteString' chunks: O(1) append by composition, run
to a chunk list in document order (RFC-0013). Constant tag and escape fragments
are pre-packed CAFs; only dynamic text packs per render.

The difference-list representation matters in mhs: @BS.append@ memcpys into a fresh
buffer, so building output by repeated @append@ would be O(n^2). Appending chunks to a
list (O(1)) and concatenating once at the socket boundary keeps it linear. (mhs ByteString
cost model: docs/design/link-index-performance.md.)
-}
newtype Builder = Builder ([ByteString] -> [ByteString])

instance Semigroup Builder where
    Builder f <> Builder g = Builder (f . g)

instance Monoid Builder where
    mempty = Builder id

-- | Appends one chunk to a builder.
chunk :: ByteString -> Builder
chunk bytes = Builder (bytes :)

-- | Runs a builder to its chunk list, in document order.
runBuilder :: Builder -> [ByteString]
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

instance IsString (Html ()) where
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
renderChunks :: Html a -> [ByteString]
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
coalesce :: Int -> [ByteString] -> [ByteString]
coalesce bufSize = finish . foldl step ([], [], 0)
  where
    step (out, cur, len) c
        | len >= bufSize = (BS.concat (reverse cur) : out, [c], BS.length c)
        | otherwise = (out, c : cur, len + BS.length c)
    finish (out, cur, _) =
        reverse (if null cur then out else BS.concat (reverse cur) : out)

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
bytesText :: ByteString -> Html ()
bytesText = emit . escapeBytes

rawTrusted :: String -> Html ()
rawTrusted = emit . chunk . BS.pack

el :: String -> [(String, String)] -> Html () -> Html ()
el name attrs children = do
    emit (openTag name attrs)
    children
    emit (closeTag name)

voidEl :: String -> [(String, String)] -> Html ()
voidEl name attrs = emit (openTag name attrs)

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

emit :: Builder -> Html ()
emit out = Html (out, ())

-- | The opening tag @\<name attrs\>@ as builder chunks.
openTag :: String -> [(String, String)] -> Builder
openTag name attrs = openBracket <> chunk (BS.pack name) <> renderAttrs attrs <> closeBracket

-- | The closing tag @\</name\>@ as builder chunks.
closeTag :: String -> Builder
closeTag name = closeOpen <> chunk (BS.pack name) <> closeBracket

renderAttrs :: [(String, String)] -> Builder
renderAttrs = foldMap renderAttr
  where
    renderAttr (name, value) =
        attrSpace <> chunk (BS.pack name) <> attrEquals <> escapeAttr value <> attrQuote

escapeText :: String -> Builder
escapeText = escapeChars

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
escapeBytes :: ByteString -> Builder
escapeBytes input =
    case BS.break isSpecial input of
        (safe, rest) -> safeChunk safe <> escapeRest rest
  where
    safeChunk safe = if BS.null safe then mempty else chunk safe
    escapeRest rest = case BS.uncons rest of
        Nothing -> mempty
        Just (c, more) -> replacement c <> escapeBytes more

isSpecial :: Char -> Bool
isSpecial c = c == '<' || c == '>' || c == '&' || c == '"' || c == '\''

replacement :: Char -> Builder
replacement '<' = ltChunk
replacement '>' = gtChunk
replacement '&' = ampChunk
replacement '"' = quotChunk
replacement '\'' = aposChunk
replacement c = chunk (BS.pack [c])

-- Pre-packed constant fragments (shared CAFs).

openBracket, closeBracket, closeOpen, attrSpace, attrEquals, attrQuote :: Builder
openBracket = chunk (BS.pack "<")
closeBracket = chunk (BS.pack ">")
closeOpen = chunk (BS.pack "</")
attrSpace = chunk (BS.pack " ")
attrEquals = chunk (BS.pack "=\"")
attrQuote = chunk (BS.pack "\"")

ltChunk, gtChunk, ampChunk, quotChunk, aposChunk :: Builder
ltChunk = chunk (BS.pack "&lt;")
gtChunk = chunk (BS.pack "&gt;")
ampChunk = chunk (BS.pack "&amp;")
quotChunk = chunk (BS.pack "&quot;")
aposChunk = chunk (BS.pack "&#39;")
