{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.HtmlSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Html as Html
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Html" $ do
        it "given a custom element with data attributes, when rendering, then escaped HTML is returned" $
            Html.renderHtml todoItem `shouldBe` expected
        it "given common document elements, when rendering, then matching HTML is returned" $
            Html.renderHtml document `shouldBe` documentExpected
        it "given blaze-style elements and overloaded strings, when rendering, then text is escaped" $
            Html.renderHtml blazeStyleDocument `shouldBe` blazeStyleExpected
        it "given a rendered document, when chunked, then the concatenated chunks equal the string render" $
            BS.unpack (BS.concat (Html.renderChunks todoItem)) `shouldBe` Html.renderHtml todoItem
        it "given UTF-8 bytes, when rendering bytesText, then specials are escaped and other bytes pass through verbatim" $
            BS.concat (Html.renderChunks (Html.bytesText (BS.pack "caf\xc3\xa9 <b> & \xf0\x9f\x98\x80")))
                `shouldBe` BS.pack "caf\xc3\xa9 &lt;b&gt; &amp; \xf0\x9f\x98\x80"
        it "given a small page, when chunked, then it coalesces to a single segment" $
            length (Html.renderChunks document) `shouldBe` 1
        it "given a page larger than the coalescing buffer, when chunked, then it splits into bounded segments" $ do
            let segments = Html.renderChunks largeDocument
            (length segments > 1) `shouldBe` True
            (BS.length (head segments) >= 16384) `shouldBe` True

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

blazeStyleDocument :: Html.Html ()
blazeStyleDocument =
    Html.html [Html.lang "en"] $ do
        Html.head [] $
            Html.title [] "MicroHttp"
        Html.body [] $
            Html.main [] $ do
                Html.h1 [] "Hello <MicroHttp>"
                Html.p [] "Overloaded strings render escaped text"

blazeStyleExpected :: String
blazeStyleExpected =
    "<html lang=\"en\"><head><title>MicroHttp</title></head>"
        ++ "<body><main><h1>Hello &lt;MicroHttp&gt;</h1>"
        ++ "<p>Overloaded strings render escaped text</p></main></body></html>"

-- | A document large enough to exceed the coalescing buffer (16 KB).
largeDocument :: Html.Html ()
largeDocument =
    mapM_ (\_ -> Html.p_ [] (Html.text "A padding paragraph used to exceed the coalescing buffer.")) [1 .. (800 :: Int)]
