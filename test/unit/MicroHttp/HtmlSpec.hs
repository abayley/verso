{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.HtmlSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Utf8 as Utf8
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Html" $ do
        it "given text holding characters above Latin-1, when rendered, then the bytes are their UTF-8 encoding (RFC-0043)" $
            BS.concat (Html.renderChunks (Html.text "caf\233 \8212 \1046 <b>")) `shouldBe` Utf8.encodeText "caf\233 \8212 \1046 &lt;b&gt;"
        it "given a custom element with data attributes, when rendering, then escaped HTML is returned" $
            Html.renderHtml todoItem `shouldBe` expected
        it "given common document elements, when rendering, then matching HTML is returned" $
            Html.renderHtml document `shouldBe` documentExpected
        it "given children written as overloaded strings, when rendering, then text is escaped" $
            Html.renderHtml overloadedStringDocument `shouldBe` overloadedStringExpected
        it "given a rendered document, when chunked, then the concatenated chunks equal the string render" $
            BS.unpack (BS.concat (Html.renderChunks todoItem)) `shouldBe` Html.renderHtml todoItem
        it "given UTF-8 bytes, when escaped, then specials are escaped and other bytes pass through verbatim" $
            escapeAndRender (BS.pack "caf\xc3\xa9 <b> & \xf0\x9f\x98\x80")
                `shouldReturn` BS.pack "caf\xc3\xa9 &lt;b&gt; &amp; \xf0\x9f\x98\x80"
        it "given bytes with no specials, when escaped, then the bytes come back unchanged" $
            escapeAndRender plainBytes `shouldReturn` plainBytes
        it "given empty bytes, when escaped, then nothing is rendered" $
            escapeAndRender BS.empty `shouldReturn` BS.empty
        it "given specials at the start, adjacent, and at the end, when escaped, then each is its entity" $
            escapeAndRender (BS.pack "<<a>>&\"'\"&")
                `shouldReturn` BS.pack "&lt;&lt;a&gt;&gt;&amp;&quot;&#39;&quot;&amp;"
        it "given a NUL byte beside a special, when escaped, then the NUL passes through and the special is escaped" $
            escapeAndRender (BS.pack "a\0<\0b") `shouldReturn` BS.pack "a\0&lt;\0b"
        it "given many specials among multibyte UTF-8, when escaped, then the output matches the per-character escaper" $
            escapeAndRender denseBytes `shouldReturn` referenceEscape denseBytes
        it "given a large document with sparse specials, when escaped, then the output matches the per-character escaper" $
            escapeAndRender sparseBytes `shouldReturn` referenceEscape sparseBytes
        it "given a small page, when chunked, then it coalesces to a single segment" $
            length (Html.renderChunks document) `shouldBe` 1
        it "given a page larger than the coalescing buffer, when chunked, then it splits into bounded segments" $ do
            let segments = Html.renderChunks largeDocument
            (length segments > 1) `shouldBe` True
            (BS.length (head segments) >= 16384) `shouldBe` True
        it "given the HtmlSpec pages, when coalesced, then the segments equal the strict coalescer" $ do
            let render = Html.renderChunksRaw
            Html.coalesce 16384 (render todoItem) `shouldBe` strictCoalesce 16384 (render todoItem)
            Html.coalesce 16384 (render document) `shouldBe` strictCoalesce 16384 (render document)
            Html.coalesce 16384 (render largeDocument) `shouldBe` strictCoalesce 16384 (render largeDocument)
        it "given a chunk list spanning several buffers, when coalesced, then it equals the strict coalescer" $
            Html.coalesce 16 manyChunks `shouldBe` strictCoalesce 16 manyChunks
        it "given empty and singleton chunk lists, when coalesced, then it equals the strict coalescer" $ do
            Html.coalesce 16 [] `shouldBe` strictCoalesce 16 []
            Html.coalesce 16 [BS.pack "abc"] `shouldBe` strictCoalesce 16 [BS.pack "abc"]
        it "given an unbounded chunk source, when coalesced, then the first buffer-sized segment is yielded without forcing the rest" $
            (BS.length (head (Html.coalesce 16 (repeat (BS.pack "abcd")))) >= 16) `shouldBe` True
        mapM_ escaperAgreementCase escaperInputs

{- | Inputs the two production escapers must agree on: each of the five specials,
the specials together, a non-special string, multibyte UTF-8, and the empty
string. Named so failures point at the offending case.
-}
escaperInputs :: [(String, String)]
escaperInputs =
    [ ("the less-than special", "<")
    , ("the greater-than special", ">")
    , ("the ampersand special", "&")
    , ("the double-quote special", "\"")
    , ("the single-quote special", "'")
    , ("all five specials together", "<>&\"'")
    , ("a string with no specials", "plain text")
    , ("multibyte UTF-8 around specials", "caf\233 \8212 \1046 <b> & '\10084'")
    , ("the empty string", "")
    ]

{- | Pins the two production HTML escapers against each other over one input, so a
future edit to one set (the Haskell 'Html.escapeChar' / 'escapeChars' String path, or
the C byte path behind 'Html.escapeBlockBytes') that is not mirrored in the other is
caught. The String path is reached through 'Html.text'; the byte path takes the input's
UTF-8 bytes. Also pins 'Html.escapedLength' as the exact byte count of 'escapeBlockBytes',
the length/transform invariant a sized streamed response relies on (RFC-0040/0049).
-}
escaperAgreementCase :: (String, String) -> Spec
escaperAgreementCase (label, input) = do
    let utf8 = Utf8.encodeText input
        stringPath = BS.concat (Html.renderChunks (Html.text input))
    it ("given " ++ label ++ ", when escaped by the String path and the byte path, then the bytes agree") $ do
        bytePath <- Html.escapeBlockBytes utf8
        bytePath `shouldBe` stringPath
    it ("given " ++ label ++ ", when its escaped length is computed, then it equals the escaped byte count") $ do
        escaped <- Html.escapeBlockBytes utf8
        Html.escapedLength utf8 `shouldReturn` BS.length escaped

todoItem :: Html.Html ()
todoItem =
    Html.custom "todo-item" [Html.attr "data-id" "42", Html.attr "data-target" "#todos"] $ do
        Html.div_ [Html.class_ "todo-title"] $
            Html.text "A <dangerous> & useful item"
        Html.input_ [Html.attr "value" "quoted \"value\""]
        Html.rawTrusted "<span data-safe=\"true\"></span>"
        Html.button_
            [ Html.attr "data-action" "/todos/42"
            , Html.attr "data-swap" "outerHTML"
            ]
            (Html.text "Delete")

expected :: String
expected =
    "<todo-item data-id=\"42\" data-target=\"#todos\">"
        ++ "<div class=\"todo-title\">A &lt;dangerous&gt; &amp; useful item</div>"
        ++ "<input value=\"quoted &quot;value&quot;\">"
        ++ "<span data-safe=\"true\"></span>"
        ++ "<button data-action=\"/todos/42\" data-swap=\"outerHTML\">Delete</button>"
        ++ "</todo-item>"

document :: Html.Html ()
document =
    Html.html_ [Html.attr "lang" "en"] $ do
        Html.head_ [] $
            Html.title_ [] (Html.text "MicroHttp")
        Html.body_ [] $ do
            Html.main_ [] $ do
                Html.h1_ [] (Html.text "Hello")
                Html.h2_ [] (Html.text "Subheading")
                Html.p_ [] (Html.text "A paragraph")
                Html.a_ [Html.href "/todos"] (Html.text "Todos")
                Html.ul_ [] $ do
                    Html.li_ [] (Html.text "one")
                    Html.li_ [] (Html.text "two")
                Html.span_ [Html.class_ "badge"] (Html.text "ready")

documentExpected :: String
documentExpected =
    "<html lang=\"en\">"
        ++ "<head><title>MicroHttp</title></head>"
        ++ "<body><main><h1>Hello</h1><h2>Subheading</h2>"
        ++ "<p>A paragraph</p><a href=\"/todos\">Todos</a>"
        ++ "<ul><li>one</li><li>two</li></ul>"
        ++ "<span class=\"badge\">ready</span></main></body>"
        ++ "</html>"

overloadedStringDocument :: Html.Html ()
overloadedStringDocument =
    Html.html_ [Html.lang "en"] $ do
        Html.head_ [] $
            Html.title_ [] "MicroHttp"
        Html.body_ [] $
            Html.main_ [] $ do
                Html.h1_ [] "Hello <MicroHttp>"
                Html.p_ [] "Overloaded strings render escaped text"

overloadedStringExpected :: String
overloadedStringExpected =
    "<html lang=\"en\"><head><title>MicroHttp</title></head>"
        ++ "<body><main><h1>Hello &lt;MicroHttp&gt;</h1>"
        ++ "<p>Overloaded strings render escaped text</p></main></body></html>"

-- | A document large enough to exceed the coalescing buffer (16 KB).
largeDocument :: Html.Html ()
largeDocument =
    mapM_ (\_ -> Html.p_ [] (Html.text "A padding paragraph used to exceed the coalescing buffer.")) [1 .. (800 :: Int)]

-- | Escapes bytes as document content and renders them, as the editor page does.
escapeAndRender :: BS.ByteString -> IO BS.ByteString
escapeAndRender bytes = do
    escaped <- Html.escapeBytes bytes
    pure (BS.concat (Html.renderChunks (Html.escapedText escaped)))

-- | Bytes with no HTML specials, including multibyte UTF-8.
plainBytes :: BS.ByteString
plainBytes = BS.concat (replicate 300 (BS.pack "caf\xc3\xa9 na\xc3\xafve \xf0\x9f\x98\x80 plain text\n"))

-- | A special-dense body: every few bytes is one of the five specials, with UTF-8 on both sides.
denseBytes :: BS.ByteString
denseBytes = BS.concat (replicate 2000 (BS.pack "\xc3\xa9<\xc3\xa9>&\"'\xf0\x9f\x98\x80'\"&><"))

-- | A ~200KB body with a special every few hundred bytes, as prose tends to have.
sparseBytes :: BS.ByteString
sparseBytes = BS.concat (replicate 800 (BS.pack (replicate 250 'x' ++ "\xc3\xa9 it's \"quoted\" a & b < c > d\n")))

{- | The per-character escaper the byte-level one replaced, kept as the oracle: it is the
definition of the five entities, so the new escaper is checked against it rather than against
itself.
-}
referenceEscape :: BS.ByteString -> BS.ByteString
referenceEscape = BS.pack . concatMap escapeChar . BS.unpack
  where
    escapeChar '<' = "&lt;"
    escapeChar '>' = "&gt;"
    escapeChar '&' = "&amp;"
    escapeChar '"' = "&quot;"
    escapeChar '\'' = "&#39;"
    escapeChar c = [c]

-- | A chunk list spanning several coalescing buffers, with uneven chunk sizes.
manyChunks :: [BS.ByteString]
manyChunks = take 400 (cycle [BS.pack "a", BS.pack "bcde", BS.pack "", BS.pack "fghijklmno", BS.pack "pq"])

{- | The strict coalescer 'Html.coalesce' replaced, kept as the oracle: it folds the whole
chunk list before yielding, so the lazy coalescer is checked against it segment for segment.
-}
strictCoalesce :: Int -> [BS.ByteString] -> [BS.ByteString]
strictCoalesce bufSize = finish . foldl step ([], [], 0)
  where
    step (out, cur, len) c
        | len >= bufSize = (BS.concat (reverse cur) : out, [c], BS.length c)
        | otherwise = (out, c : cur, len + BS.length c)
    finish (out, cur, _) =
        reverse (if null cur then out else BS.concat (reverse cur) : out)
