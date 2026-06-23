module MicroHttp.DocumentLinksSpec (spec) where

import MicroHttp.DocumentLinks
import Test.Hspec

-- | The substring a link's span points at (to check spans without hand-counting offsets).
spanText :: String -> Link -> String
spanText text link = take (linkEnd link - linkStart link) (drop (linkStart link) text)

spec :: Spec
spec =
    describe "MicroHttp.DocumentLinks" $ do
        describe "pageLinks" $ do
            it "extracts inline link and image targets with accurate spans" $ do
                let text = "See [Runbook](./runbook.md) and ![diagram](assets/d.png).\n"
                    links = pageLinks text
                map linkTarget links `shouldBe` ["./runbook.md", "assets/d.png"]
                map (spanText text) links `shouldBe` ["./runbook.md", "assets/d.png"]

            it "preserves a target's #anchor/?query in the token" $ do
                map linkTarget (pageLinks "[x](../a/b.md#section)") `shouldBe` ["../a/b.md#section"]

            it "drops a title and angle brackets from the target span" $ do
                map linkTarget (pageLinks "[x](./a.md \"Title\") [y](<./b.md>)")
                    `shouldBe` ["./a.md", "./b.md"]

            it "skips fenced code blocks" $ do
                let text = "[real](./a.md)\n```\n[code](./b.md)\n```\n[also](./c.md)\n"
                map linkTarget (pageLinks text) `shouldBe` ["./a.md", "./c.md"]

            it "ignores reference-style definitions and reference uses (no '](')" $ do
                map linkTarget (pageLinks "[id]: ./x.md\nSee [text][id].\n") `shouldBe` []

        describe "splitTargetSuffix" $ do
            it "splits a path from its #anchor or ?query" $ do
                splitTargetSuffix "foo.md#sec" `shouldBe` ("foo.md", "#sec")
                splitTargetSuffix "foo.md?x=1" `shouldBe` ("foo.md", "?x=1")
                splitTargetSuffix "foo.md" `shouldBe` ("foo.md", "")

        describe "isExternalTarget" $ do
            it "is true for schemes, protocol-relative, absolute, and pure anchors" $ do
                map isExternalTarget ["https://e.com", "mailto:a@b", "//cdn/x", "/abs/x.md", "#sec"]
                    `shouldBe` [True, True, True, True, True]

            it "is false for relative targets" $ do
                map isExternalTarget ["./a.md", "../b/c.md", "assets/x.png", "d.md#s"]
                    `shouldBe` [False, False, False, False]

        describe "resolveTarget" $ do
            it "resolves same-dir, ./, ../ and ../.. against the linking directory" $ do
                resolveTarget "a/b" "./foo.md" `shouldBe` Just "a/b/foo.md"
                resolveTarget "a/b" "foo.md" `shouldBe` Just "a/b/foo.md"
                resolveTarget "a/b" "../x.md" `shouldBe` Just "a/x.md"
                resolveTarget "a/b" "../../y.md" `shouldBe` Just "y.md"
                resolveTarget "" "a/foo.md" `shouldBe` Just "a/foo.md"

            it "drops the anchor when resolving" $ do
                resolveTarget "a/b" "../x.md#sec" `shouldBe` Just "a/x.md"

            it "is Nothing for an external target or one escaping the root" $ do
                resolveTarget "a/b" "https://e.com" `shouldBe` Nothing
                resolveTarget "a" "../../escape.md" `shouldBe` Nothing

        describe "relativeBetween" $ do
            it "uses ./ for same-dir and descendants, ../ chains for ancestors/siblings" $ do
                relativeBetween "a/b" "a/b/foo.md" `shouldBe` "./foo.md"
                relativeBetween "a/b" "a/b/c/d.md" `shouldBe` "./c/d.md"
                relativeBetween "a/b" "a/x.md" `shouldBe` "../x.md"
                relativeBetween "a/b" "a/c/d.md" `shouldBe` "../c/d.md"
                relativeBetween "a/b" "x.md" `shouldBe` "../../x.md"
                relativeBetween "" "a/foo.md" `shouldBe` "./a/foo.md"

            it "round-trips with resolveTarget" $ do
                resolveTarget "a/b" (relativeBetween "a/b" "a/c/d.md") `shouldBe` Just "a/c/d.md"
                resolveTarget "deep/x/y" (relativeBetween "deep/x/y" "other/z.md") `shouldBe` Just "other/z.md"

        describe "rewriteLinks" $ do
            it "replaces spans and preserves everything else byte-for-byte" $ do
                let text = "a [L](./old.md) b ![i](assets/x.png) c"
                    links = pageLinks text
                    edits = [(linkStart l, linkEnd l, "NEW") | l <- links]
                rewriteLinks text edits `shouldBe` "a [L](NEW) b ![i](NEW) c"

            it "is a no-op with no edits" $ do
                rewriteLinks "unchanged" [] `shouldBe` "unchanged"
