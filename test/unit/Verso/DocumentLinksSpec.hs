module Verso.DocumentLinksSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import Test.Hspec
import qualified Verso.DocumentLinks as DocumentLinks

-- | A page body as bytes (the link engine works over 'ByteString' now, RFC-0029).
bs :: String -> BS.ByteString
bs = BS.pack

-- | The substring a link's span points at (to check spans without hand-counting offsets).
spanText :: BS.ByteString -> DocumentLinks.Link -> String
spanText text link = BS.unpack (BS.take (DocumentLinks.linkEnd link - DocumentLinks.linkStart link) (BS.drop (DocumentLinks.linkStart link) text))

spec :: Spec
spec =
    describe "Verso.DocumentLinks" $ do
        describe "pageLinks" $ do
            it "extracts inline link and image targets with accurate spans" $ do
                let text = bs "See [Runbook](./runbook.md) and ![diagram](assets/d.png).\n"
                    links = DocumentLinks.pageLinks text
                map DocumentLinks.linkTarget links `shouldBe` ["./runbook.md", "assets/d.png"]
                map (spanText text) links `shouldBe` ["./runbook.md", "assets/d.png"]

            it "preserves a target's #anchor/?query in the token" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[x](../a/b.md#section)")) `shouldBe` ["../a/b.md#section"]

            it "drops a title and angle brackets from the target span" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[x](./a.md \"Title\") [y](<./b.md>)"))
                    `shouldBe` ["./a.md", "./b.md"]

            it "skips fenced code blocks" $ do
                let text = bs "[real](./a.md)\n```\n[code](./b.md)\n```\n[also](./c.md)\n"
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks text) `shouldBe` ["./a.md", "./c.md"]

            it "ignores reference-style definitions and reference uses (no '](')" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[id]: ./x.md\nSee [text][id].\n")) `shouldBe` []

            it "requires the closing paren on the same line" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[x](./a.md\nmore) [y](./b.md)\n"))
                    `shouldBe` ["./b.md"]

            it "emits an empty token for a bare '](' and still finds the later link on the line" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "broken ]( then [x](./a.md) after\n"))
                    `shouldBe` ["", "./a.md"]

            it "skips tilde fences like backtick fences" $ do
                let text = bs "[real](./a.md)\n~~~\n[code](./b.md)\n~~~\n[also](./c.md)\n"
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks text) `shouldBe` ["./a.md", "./c.md"]

            it "finds a link on the final line without a trailing newline" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "text\n[x](./a.md)")) `shouldBe` ["./a.md"]

            it "finds nothing in an unterminated fence" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "```\n[x](./a.md)\n")) `shouldBe` []

        describe "splitTargetSuffix" $ do
            it "splits a path from its #anchor or ?query" $ do
                DocumentLinks.splitTargetSuffix "foo.md#sec" `shouldBe` ("foo.md", "#sec")
                DocumentLinks.splitTargetSuffix "foo.md?x=1" `shouldBe` ("foo.md", "?x=1")
                DocumentLinks.splitTargetSuffix "foo.md" `shouldBe` ("foo.md", "")

        describe "isExternalTarget" $ do
            it "is true for schemes, protocol-relative, absolute, and pure anchors" $ do
                map DocumentLinks.isExternalTarget ["https://e.com", "mailto:a@b", "//cdn/x", "/abs/x.md", "#sec"]
                    `shouldBe` [True, True, True, True, True]

            it "is false for relative targets" $ do
                map DocumentLinks.isExternalTarget ["./a.md", "../b/c.md", "assets/x.png", "d.md#s"]
                    `shouldBe` [False, False, False, False]

        describe "resolveTarget" $ do
            it "resolves same-dir, ./, ../ and ../.. against the linking directory" $ do
                DocumentLinks.resolveTarget "a/b" "./foo.md" `shouldBe` Just "a/b/foo.md"
                DocumentLinks.resolveTarget "a/b" "foo.md" `shouldBe` Just "a/b/foo.md"
                DocumentLinks.resolveTarget "a/b" "../x.md" `shouldBe` Just "a/x.md"
                DocumentLinks.resolveTarget "a/b" "../../y.md" `shouldBe` Just "y.md"
                DocumentLinks.resolveTarget "" "a/foo.md" `shouldBe` Just "a/foo.md"

            it "drops the anchor when resolving" $ do
                DocumentLinks.resolveTarget "a/b" "../x.md#sec" `shouldBe` Just "a/x.md"

            it "is Nothing for an external target or one escaping the root" $ do
                DocumentLinks.resolveTarget "a/b" "https://e.com" `shouldBe` Nothing
                DocumentLinks.resolveTarget "a" "../../escape.md" `shouldBe` Nothing

        describe "relativeBetween" $ do
            it "uses ./ for same-dir and descendants, ../ chains for ancestors/siblings" $ do
                DocumentLinks.relativeBetween "a/b" "a/b/foo.md" `shouldBe` "./foo.md"
                DocumentLinks.relativeBetween "a/b" "a/b/c/d.md" `shouldBe` "./c/d.md"
                DocumentLinks.relativeBetween "a/b" "a/x.md" `shouldBe` "../x.md"
                DocumentLinks.relativeBetween "a/b" "a/c/d.md" `shouldBe` "../c/d.md"
                DocumentLinks.relativeBetween "a/b" "x.md" `shouldBe` "../../x.md"
                DocumentLinks.relativeBetween "" "a/foo.md" `shouldBe` "./a/foo.md"

            it "round-trips with resolveTarget" $ do
                DocumentLinks.resolveTarget "a/b" (DocumentLinks.relativeBetween "a/b" "a/c/d.md") `shouldBe` Just "a/c/d.md"
                DocumentLinks.resolveTarget "deep/x/y" (DocumentLinks.relativeBetween "deep/x/y" "other/z.md") `shouldBe` Just "other/z.md"

        describe "rewriteLinks" $ do
            it "replaces spans and preserves everything else byte-for-byte" $ do
                let text = bs "a [L](./old.md) b ![i](assets/x.png) c"
                    links = DocumentLinks.pageLinks text
                    edits = [(DocumentLinks.linkStart l, DocumentLinks.linkEnd l, "NEW") | l <- links]
                DocumentLinks.rewriteLinks text edits `shouldBe` bs "a [L](NEW) b ![i](NEW) c"

            it "is a no-op with no edits" $ do
                DocumentLinks.rewriteLinks (bs "unchanged") [] `shouldBe` bs "unchanged"

        describe "relocatePath" $ do
            it "relocates the subtree root and its descendants, leaving others" $ do
                DocumentLinks.relocatePath "a/b" "c/b" "a/b" `shouldBe` Just "c/b"
                DocumentLinks.relocatePath "a/b" "c/b" "a/b/index.md" `shouldBe` Just "c/b/index.md"
                DocumentLinks.relocatePath "a/b" "c/b" "a/b/sub/x.md" `shouldBe` Just "c/b/sub/x.md"
                DocumentLinks.relocatePath "a/b" "c/b" "a/other.md" `shouldBe` Nothing
                DocumentLinks.relocatePath "a/b" "c/b" "a/bc/x.md" `shouldBe` Nothing

            it "handles a rename in place (same parent, new slug)" $ do
                DocumentLinks.relocatePath "a/b" "a/bnew" "a/b/x.md" `shouldBe` Just "a/bnew/x.md"

        describe "planMoveRewrites" $ do
            it "rewrites an inbound link from outside the moved subtree" $ do
                let pages =
                        [ ("a/index.md", bs "See [B](./b/index.md).\n")
                        , ("a/b/index.md", bs "# B\n")
                        ]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages
                    `shouldBe` [("a/index.md", bs "See [B](../c/b/index.md).\n")]

            it "leaves intra-subtree links untouched on a plain move" $ do
                let pages =
                        [ ("a/b/index.md", bs "Child [P](./p.md) and [Q](./sub/q.md).\n")
                        , ("a/b/p.md", bs "Up [Idx](./index.md).\n")
                        ]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages `shouldBe` []

            it "fixes the moved page's outward link to a non-moved target" $ do
                let pages = [("a/b/p.md", bs "Out [Z](../z.md).\n")]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages
                    `shouldBe` [("a/b/p.md", bs "Out [Z](../../a/z.md).\n")]

            it "fixes an internal link routing through the old name on a rename" $ do
                let pages = [("a/b/sub/p.md", bs "Sib [O](../../b/other.md).\n")]
                DocumentLinks.planMoveRewrites ("a/b", "a/bnew") pages
                    `shouldBe` [("a/b/sub/p.md", bs "Sib [O](../other.md).\n")]

            it "leaves external targets and code-fenced links alone" $ do
                let pages = [("a/index.md", bs "[E](https://x.test) and `code`.\n")]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages `shouldBe` []

            it "preserves a target's anchor suffix when rewriting" $ do
                let pages = [("a/index.md", bs "[B](./b/index.md#intro)\n")]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages
                    `shouldBe` [("a/index.md", bs "[B](../c/b/index.md#intro)\n")]

        describe "planPageMove" $ do
            it "rewrites the moved page's outward links and leaves its travelling assets bare" $ do
                let pages =
                        [ ("a/old.md", bs "Link [Other](./other.md) and ![img](assets/x.png).\n")
                        , ("a/other.md", bs "Back [Old](./old.md).\n")
                        ]
                    result = DocumentLinks.planPageMove ("a/old.md", "b/old.md") pages
                lookup "b/old.md" result
                    `shouldBe` Just (bs "Link [Other](../a/other.md) and ![img](assets/x.png).\n")
                lookup "a/other.md" result
                    `shouldBe` Just (bs "Back [Old](../b/old.md).\n")

            it "leaves a same-folder rename's own links untouched and fixes inbound links" $ do
                let pages =
                        [ ("a/old.md", bs "Self [Sib](./sib.md) and ![img](assets/x.png).\n")
                        , ("a/sib.md", bs "To [Old](./old.md).\n")
                        ]
                    result = DocumentLinks.planPageMove ("a/old.md", "a/new.md") pages
                lookup "a/new.md" result `shouldBe` Nothing
                lookup "a/sib.md" result `shouldBe` Just (bs "To [Old](./new.md).\n")

        describe "assetNamesIn" $ do
            it "extracts asset basenames from body link and image targets" $ do
                DocumentLinks.assetNamesIn (bs "![d](assets/diagram.png) and [f](./assets/report.pdf) and [x](./other.md)")
                    `shouldBe` ["diagram.png", "report.pdf"]

        describe "classifyAssets" $ do
            it "marks an asset shared when any peer references it, exclusive otherwise" $ do
                DocumentLinks.classifyAssets ["a.png", "b.png"] [["a.png"], ["c.png"]]
                    `shouldBe` [("a.png", DocumentLinks.SharedAsset), ("b.png", DocumentLinks.ExclusiveAsset)]

        describe "referrersMatching" $ do
            it "finds pages linking to a target, excluding listed pages, with the raw link" $ do
                let pages =
                        [ ("a/index.md", bs "Card [P](./p.md)\n")
                        , ("a/other.md", bs "See [P](./p.md) twice [P](./p.md#x)\n")
                        , ("a/p.md", bs "self [me](./p.md)\n")
                        ]
                DocumentLinks.referrersMatching (== "a/p.md") ["a/index.md", "a/p.md"] pages
                    `shouldBe` [("a/other.md", "./p.md"), ("a/other.md", "./p.md#x")]

            it "matches a subtree predicate for a section delete" $ do
                let pages =
                        [ ("top.md", bs "Into [X](./sec/sub/x.md)\n")
                        , ("sec/inside.md", bs "Sibling [Y](./y.md)\n")
                        ]
                    inSubtree t = t == "sec" || ("sec/" `List.isPrefixOf` t)
                DocumentLinks.referrersMatching inSubtree ["sec/inside.md"] pages
                    `shouldBe` [("top.md", "./sec/sub/x.md")]
