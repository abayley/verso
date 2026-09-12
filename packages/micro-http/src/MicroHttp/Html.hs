module MicroHttp.Html (
    Html,
    attr,
    a,
    a_,
    button,
    button_,
    body,
    body_,
    Escaped,
    escapeBytes,
    escapeBlockBytes,
    escapedLength,
    escapedText,
    class_,
    custom,
    div,
    div_,
    el,
    elOpen,
    elClose,
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
    coalesce,
    renderChunks,
    renderChunksRaw,
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
import qualified Data.ByteString.Unsafe as BSU
import qualified Data.String as String
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import Prelude hiding (div, head, span)

foreign import ccall "microhttp_html.h mhhtml_escaped_length" c_escapedLength :: Ptr.Ptr CTypes.CUChar -> CTypes.CLong -> IO CTypes.CLong
foreign import ccall "microhttp_html.h mhhtml_escape" c_escape :: Ptr.Ptr CTypes.CUChar -> CTypes.CLong -> Ptr.Ptr CTypes.CUChar -> IO CTypes.CLong

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
renderChunks = coalesce coalesceBufferSize . renderChunksRaw

{- | The builder's fragment list before coalescing: many small chunks, one per
emitted fragment. The response path coalesces these (via 'renderChunks'); a
caller that streams a page around a document hole coalesces the shell segments
itself, so it needs the raw fragments.
-}
renderChunksRaw :: Html a -> [BS.ByteString]
renderChunksRaw = runBuilder . htmlBuilder

-- | The accumulated builder of a rendered document.
htmlBuilder :: Html a -> Builder
htmlBuilder (Html (out, _)) = out

-- | Coalescing segment size: many small fragments become few buffer-sized writes.
coalesceBufferSize :: Int
coalesceBufferSize = 16384

{- | Packs a chunk list into segments of at least @bufSize@ bytes, yielding each
segment as soon as it fills rather than folding the whole list first, so the
builder's lazy fragment list flows through with only one segment in hand
(RFC-0040). A page below the buffer is a single segment. Byte-identical, segment
for segment, to the strict coalescer it replaced: a segment accumulates chunks
until its total reaches @bufSize@, and the next chunk starts a fresh segment.
-}
coalesce :: Int -> [BS.ByteString] -> [BS.ByteString]
coalesce bufSize = go [] 0
  where
    go cur _ [] = [BS.concat (reverse cur) | not (null cur)]
    go cur len (c : cs)
        | len >= bufSize = BS.concat (reverse cur) : go [c] (BS.length c) cs
        | otherwise = go (c : cur) (len + BS.length c) cs

-- | Emit escaped text from a 'String', decoding via the 'String' path.
text :: String -> Html ()
text = emit . escapeText

{- | Bytes already escaped for HTML text content by 'escapeBytes'. Opaque, so the
only way to obtain one is to escape, and a view can take one to say its content
is safe to emit without knowing where it came from.
-}
newtype Escaped = Escaped BS.ByteString

{- | Escapes a 'ByteString' that is already UTF-8 (e.g. a document read straight
off disk) for HTML text content. The five HTML-significant bytes become their
entities and every other byte -- including all UTF-8 continuation bytes -- passes
through verbatim, with no 'String' round-trip and no encoding/decoding, which is
the only correct marshalling given MicroHs decodes 'String' I/O as UTF-8 but
treats 'Data.ByteString.Char8' as raw bytes.

The work is done in C (@cbits/microhttp_html.c@, RFC-0039): the input is read in
place, its escaped length is computed, and the escaped bytes are written into a
private buffer that is packed into the result and freed. Memory is the input plus
the output, never a per-byte list. In 'IO' because it writes that buffer; ADR-0086
reserves 'unsafePerformIO' for read-only scans. An input with no specials is
returned as-is, without a copy.
-}
escapeBytes :: BS.ByteString -> IO Escaped
escapeBytes = fmap Escaped . escapeBlockBytes

{- | Escapes one block of already-UTF-8 bytes to its raw escaped bytes, the same
five entities as 'escapeBytes' with everything else verbatim. Because the C pass
works byte by byte, a block boundary can never split an expansion, so escaping a
document a block at a time and concatenating the results is byte-identical to
escaping it whole (RFC-0040): this is what lets a document response stream from
disk in blocks. A block with no specials is returned as-is, without a copy.
-}
escapeBlockBytes :: BS.ByteString -> IO BS.ByteString
escapeBlockBytes input
    | BS.null input = pure input
    | otherwise = BSU.unsafeUseAsCStringLen input $ \(inPtr, len) -> do
        let inBytes = Ptr.castPtr inPtr
            cLen = fromIntegral len
        escapedLen <- c_escapedLength inBytes cLen
        if escapedLen == cLen
            then pure input
            else Alloc.allocaBytes (fromIntegral escapedLen) $ \outBytes -> do
                written <- c_escape inBytes cLen outBytes
                BS.packCStringLen (Ptr.castPtr outBytes, fromIntegral written)

{- | The number of bytes one block escapes to, without producing the escaped
bytes. Summed over a document's blocks it gives the exact escaped length for a
sized response's @Content-Length@ (RFC-0040); byte-wise like 'escapeBlockBytes',
so the per-block sum equals the whole document's escaped length.
-}
escapedLength :: BS.ByteString -> IO Int
escapedLength input
    | BS.null input = pure 0
    | otherwise = BSU.unsafeUseAsCStringLen input $ \(inPtr, len) -> do
        escapedLen <- c_escapedLength (Ptr.castPtr inPtr) (fromIntegral len)
        pure (fromIntegral escapedLen)

-- | Emit already-escaped bytes as text content, as one chunk.
escapedText :: Escaped -> Html ()
escapedText (Escaped bytes)
    | BS.null bytes = pure ()
    | otherwise = emit (chunk bytes)

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

{- | Emit only an element's opening tag. Paired with 'elClose', it lets a caller
place a streamed hole between the tags rather than passing the whole child value:
@elOpen n a@ then content then @elClose n@ is byte-identical to @el n a content@,
which is how a document page streams around its content (RFC-0040).
-}
elOpen :: String -> [(String, String)] -> Html ()
elOpen name attrs = emit (openTag name attrs)

-- | Emit only an element's closing tag; see 'elOpen'.
elClose :: String -> Html ()
elClose name = emit (closeTag name)

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

{- | Escapes the five HTML-significant characters into a single packed chunk.
Byte-identical to the per-character renderer.

Escaping emits one chunk for the whole string rather than a @Builder@ node per
special: composing thousands of @<>@ nodes is the dominant render cost in mhs
(~1 ms per node to force), so a page with hundreds of specials would otherwise
take seconds to serialise. Packing the escaped byte stream in one pass keeps it
linear (docs/design/link-index-performance.md).
-}
escapeChars :: String -> Builder
escapeChars [] = mempty
escapeChars input = chunk (BS.pack (concatMap escapeChar input))

-- | The escaped form of one character; the identity fragment for safe characters.
escapeChar :: Char -> String
escapeChar '<' = "&lt;"
escapeChar '>' = "&gt;"
escapeChar '&' = "&amp;"
escapeChar '"' = "&quot;"
escapeChar '\'' = "&#39;"
escapeChar c = [c]

-- Pre-packed constant fragments (shared CAFs).

-- | Pre-packed structural fragments for tags and attributes.
openBracket, closeBracket, closeOpen, attrSpace, attrEquals, attrQuote :: Builder
openBracket = chunk (BS.pack "<")
closeBracket = chunk (BS.pack ">")
closeOpen = chunk (BS.pack "</")
attrSpace = chunk (BS.pack " ")
attrEquals = chunk (BS.pack "=\"")
attrQuote = chunk (BS.pack "\"")
