{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.HtmlSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Html as H
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Html" $ do
        it "given htmx custom element, when rendering, then escaped HTML is returned" $
            H.renderHtml todoItem `shouldBe` expected
        it "given common document elements, when rendering, then matching HTML is returned" $
            H.renderHtml document `shouldBe` documentExpected
        it "given blaze-style elements and overloaded strings, when rendering, then text is escaped" $
            H.renderHtml blazeStyleDocument `shouldBe` blazeStyleExpected
        it "given a rendered document, when chunked, then the concatenated chunks equal the string render" $
            BS.unpack (BS.concat (H.renderChunks todoItem)) `shouldBe` H.renderHtml todoItem
        it "given UTF-8 bytes, when rendering bytesText, then specials are escaped and other bytes pass through verbatim" $
            BS.concat (H.renderChunks (H.bytesText (BS.pack "caf\xc3\xa9 <b> & \xf0\x9f\x98\x80")))
                `shouldBe` BS.pack "caf\xc3\xa9 &lt;b&gt; &amp; \xf0\x9f\x98\x80"
        it "given a small page, when chunked, then it coalesces to a single segment" $
            length (H.renderChunks document) `shouldBe` 1
        it "given a page larger than the coalescing buffer, when chunked, then it splits into bounded segments" $ do
            let segments = H.renderChunks largeDocument
            (length segments > 1) `shouldBe` True
            (BS.length (head segments) >= 16384) `shouldBe` True

todoItem :: H.Html ()
todoItem =
    H.custom "todo-item" [H.attr "data-id" "42", H.hxTarget "#todos"] $ do
        H.div_ [H.class_ "todo-title"] $
            H.text "A <dangerous> & useful item"
        H.input_ [H.attr "value" "quoted \"value\""]
        H.rawTrusted "<span data-safe=\"true\"></span>"
        H.button_
            [ H.hxDelete "/todos/42"
            , H.hxSwap "outerHTML"
            ]
            (H.text "Delete")

expected :: String
expected =
    "<todo-item data-id=\"42\" hx-target=\"#todos\">"
        ++ "<div class=\"todo-title\">A &lt;dangerous&gt; &amp; useful item</div>"
        ++ "<input value=\"quoted &quot;value&quot;\">"
        ++ "<span data-safe=\"true\"></span>"
        ++ "<button hx-delete=\"/todos/42\" hx-swap=\"outerHTML\">Delete</button>"
        ++ "</todo-item>"

document :: H.Html ()
document =
    H.html_ [H.attr "lang" "en"] $ do
        H.head_ [] $
            H.title_ [] (H.text "MicroHttp")
        H.body_ [] $ do
            H.main_ [] $ do
                H.h1_ [] (H.text "Hello")
                H.h2_ [] (H.text "Subheading")
                H.p_ [] (H.text "A paragraph")
                H.a_ [H.href "/todos"] (H.text "Todos")
                H.ul_ [] $ do
                    H.li_ [] (H.text "one")
                    H.li_ [] (H.text "two")
                H.span_ [H.class_ "badge"] (H.text "ready")

documentExpected :: String
documentExpected =
    "<html lang=\"en\">"
        ++ "<head><title>MicroHttp</title></head>"
        ++ "<body><main><h1>Hello</h1><h2>Subheading</h2>"
        ++ "<p>A paragraph</p><a href=\"/todos\">Todos</a>"
        ++ "<ul><li>one</li><li>two</li></ul>"
        ++ "<span class=\"badge\">ready</span></main></body>"
        ++ "</html>"

blazeStyleDocument :: H.Html ()
blazeStyleDocument =
    H.html [H.lang "en"] $ do
        H.head [] $
            H.title [] "MicroHttp"
        H.body [] $
            H.main [] $ do
                H.h1 [] "Hello <MicroHttp>"
                H.p [] "Overloaded strings render escaped text"

blazeStyleExpected :: String
blazeStyleExpected =
    "<html lang=\"en\"><head><title>MicroHttp</title></head>"
        ++ "<body><main><h1>Hello &lt;MicroHttp&gt;</h1>"
        ++ "<p>Overloaded strings render escaped text</p></main></body></html>"

-- | A document large enough to exceed the coalescing buffer (16 KB).
largeDocument :: H.Html ()
largeDocument =
    mapM_ (\_ -> H.p_ [] (H.text "A padding paragraph used to exceed the coalescing buffer.")) [1 .. (800 :: Int)]
