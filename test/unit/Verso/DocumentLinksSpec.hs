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
            it "given inline links and images, when extracted, then their targets and spans are returned" $ do
                let text = bs "See [Runbook](./runbook.md) and ![diagram](assets/d.png).\n"
                    links = DocumentLinks.pageLinks text
                map DocumentLinks.linkTarget links `shouldBe` ["./runbook.md", "assets/d.png"]
                map (spanText text) links `shouldBe` ["./runbook.md", "assets/d.png"]

            it "given a target with an anchor or query, when extracted, then the suffix is kept in the token" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[x](../a/b.md#section)")) `shouldBe` ["../a/b.md#section"]

            it "given a target with a title or angle brackets, when extracted, then only the target is spanned" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[x](./a.md \"Title\") [y](<./b.md>)"))
                    `shouldBe` ["./a.md", "./b.md"]

            it "given links inside a backtick fence, when extracted, then only the links outside it are returned" $ do
                let text = bs "[real](./a.md)\n```\n[code](./b.md)\n```\n[also](./c.md)\n"
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks text) `shouldBe` ["./a.md", "./c.md"]

            it "given reference-style definitions and uses, when extracted, then nothing is returned" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[id]: ./x.md\nSee [text][id].\n")) `shouldBe` []

            it "given a link whose closing paren is on the next line, when extracted, then only the complete link is returned" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "[x](./a.md\nmore) [y](./b.md)\n"))
                    `shouldBe` ["./b.md"]

            it "given a bare '](' before a link, when extracted, then an empty token and the later link are returned" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "broken ]( then [x](./a.md) after\n"))
                    `shouldBe` ["", "./a.md"]

            it "given links inside a tilde fence, when extracted, then only the links outside it are returned" $ do
                let text = bs "[real](./a.md)\n~~~\n[code](./b.md)\n~~~\n[also](./c.md)\n"
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks text) `shouldBe` ["./a.md", "./c.md"]

            it "given a link on a final line with no trailing newline, when extracted, then it is found" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "text\n[x](./a.md)")) `shouldBe` ["./a.md"]

            it "given a link inside an unterminated fence, when extracted, then nothing is returned" $ do
                map DocumentLinks.linkTarget (DocumentLinks.pageLinks (bs "```\n[x](./a.md)\n")) `shouldBe` []

        describe "splitTargetSuffix" $ do
            it "given a target with an anchor or query, when split, then the path and the suffix are returned" $ do
                DocumentLinks.splitTargetSuffix "foo.md#sec" `shouldBe` ("foo.md", "#sec")
                DocumentLinks.splitTargetSuffix "foo.md?x=1" `shouldBe` ("foo.md", "?x=1")
                DocumentLinks.splitTargetSuffix "foo.md" `shouldBe` ("foo.md", "")

        describe "isExternalTarget" $ do
            it "given schemed, protocol-relative, absolute and anchor targets, when classified, then each is external" $ do
                map DocumentLinks.isExternalTarget ["https://e.com", "mailto:a@b", "//cdn/x", "/abs/x.md", "#sec"]
                    `shouldBe` [True, True, True, True, True]

            it "given relative targets, when classified, then none is external" $ do
                map DocumentLinks.isExternalTarget ["./a.md", "../b/c.md", "assets/x.png", "d.md#s"]
                    `shouldBe` [False, False, False, False]

        describe "resolveTarget" $ do
            it "given same-dir, ./, ../ and ../.. targets, when resolved, then each lands relative to the linking directory" $ do
                DocumentLinks.resolveTarget "a/b" "./foo.md" `shouldBe` Just "a/b/foo.md"
                DocumentLinks.resolveTarget "a/b" "foo.md" `shouldBe` Just "a/b/foo.md"
                DocumentLinks.resolveTarget "a/b" "../x.md" `shouldBe` Just "a/x.md"
                DocumentLinks.resolveTarget "a/b" "../../y.md" `shouldBe` Just "y.md"
                DocumentLinks.resolveTarget "" "a/foo.md" `shouldBe` Just "a/foo.md"

            it "given a target with an anchor, when resolved, then the anchor is dropped" $ do
                DocumentLinks.resolveTarget "a/b" "../x.md#sec" `shouldBe` Just "a/x.md"

            it "given an external target or one escaping the root, when resolved, then nothing is returned" $ do
                DocumentLinks.resolveTarget "a/b" "https://e.com" `shouldBe` Nothing
                DocumentLinks.resolveTarget "a" "../../escape.md" `shouldBe` Nothing

        describe "relativeBetween" $ do
            it "given pages in the same directory, in descendants and in siblings, when a relative link is built, then ./ and ../ chains are used" $ do
                DocumentLinks.relativeBetween "a/b" "a/b/foo.md" `shouldBe` "./foo.md"
                DocumentLinks.relativeBetween "a/b" "a/b/c/d.md" `shouldBe` "./c/d.md"
                DocumentLinks.relativeBetween "a/b" "a/x.md" `shouldBe` "../x.md"
                DocumentLinks.relativeBetween "a/b" "a/c/d.md" `shouldBe` "../c/d.md"
                DocumentLinks.relativeBetween "a/b" "x.md" `shouldBe` "../../x.md"
                DocumentLinks.relativeBetween "" "a/foo.md" `shouldBe` "./a/foo.md"

            it "given a relative link built between two pages, when it is resolved again, then the original target comes back" $ do
                DocumentLinks.resolveTarget "a/b" (DocumentLinks.relativeBetween "a/b" "a/c/d.md") `shouldBe` Just "a/c/d.md"
                DocumentLinks.resolveTarget "deep/x/y" (DocumentLinks.relativeBetween "deep/x/y" "other/z.md") `shouldBe` Just "other/z.md"

        describe "rewriteLinks" $ do
            it "given edits for some spans, when rewritten, then those spans change and every other byte is preserved" $ do
                let text = bs "a [L](./old.md) b ![i](assets/x.png) c"
                    links = DocumentLinks.pageLinks text
                    edits = [(DocumentLinks.linkStart l, DocumentLinks.linkEnd l, "NEW") | l <- links]
                DocumentLinks.rewriteLinks text edits `shouldBe` bs "a [L](NEW) b ![i](NEW) c"

            it "given no edits, when rewritten, then the content is unchanged" $ do
                DocumentLinks.rewriteLinks (bs "unchanged") [] `shouldBe` bs "unchanged"

        describe "relocatePath" $ do
            it "given a moved subtree, when paths are relocated, then its root and descendants move and others do not" $ do
                DocumentLinks.relocatePath "a/b" "c/b" "a/b" `shouldBe` Just "c/b"
                DocumentLinks.relocatePath "a/b" "c/b" "a/b/index.md" `shouldBe` Just "c/b/index.md"
                DocumentLinks.relocatePath "a/b" "c/b" "a/b/sub/x.md" `shouldBe` Just "c/b/sub/x.md"
                DocumentLinks.relocatePath "a/b" "c/b" "a/other.md" `shouldBe` Nothing
                DocumentLinks.relocatePath "a/b" "c/b" "a/bc/x.md" `shouldBe` Nothing

            it "given a rename in place, when paths are relocated, then descendants take the new slug" $ do
                DocumentLinks.relocatePath "a/b" "a/bnew" "a/b/x.md" `shouldBe` Just "a/bnew/x.md"

        describe "planMoveRewrites" $ do
            it "given a page outside the moved subtree linking into it, when the move is planned, then its link is rewritten" $ do
                let pages =
                        [ ("a/index.md", bs "See [B](./b/index.md).\n")
                        , ("a/b/index.md", bs "# B\n")
                        ]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages
                    `shouldBe` [("a/index.md", bs "See [B](../c/b/index.md).\n")]

            it "given links within the moved subtree, when a plain move is planned, then they are untouched" $ do
                let pages =
                        [ ("a/b/index.md", bs "Child [P](./p.md) and [Q](./sub/q.md).\n")
                        , ("a/b/p.md", bs "Up [Idx](./index.md).\n")
                        ]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages `shouldBe` []

            it "given a moved page linking to a target that stays put, when the move is planned, then its link is fixed" $ do
                let pages = [("a/b/p.md", bs "Out [Z](../z.md).\n")]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages
                    `shouldBe` [("a/b/p.md", bs "Out [Z](../../a/z.md).\n")]

            it "given an internal link routing through the old name, when a rename is planned, then it is fixed" $ do
                let pages = [("a/b/sub/p.md", bs "Sib [O](../../b/other.md).\n")]
                DocumentLinks.planMoveRewrites ("a/b", "a/bnew") pages
                    `shouldBe` [("a/b/sub/p.md", bs "Sib [O](../other.md).\n")]

            it "given external targets and code-fenced links, when the move is planned, then they are left alone" $ do
                let pages = [("a/index.md", bs "[E](https://x.test) and `code`.\n")]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages `shouldBe` []

            it "given a link carrying an anchor, when the move is planned, then the anchor is preserved" $ do
                let pages = [("a/index.md", bs "[B](./b/index.md#intro)\n")]
                DocumentLinks.planMoveRewrites ("a/b", "c/b") pages
                    `shouldBe` [("a/index.md", bs "[B](../c/b/index.md#intro)\n")]

        describe "planPageMove" $ do
            it "given a page moving with its assets, when the move is planned, then its outward links are rewritten and the asset links stay bare" $ do
                let pages =
                        [ ("a/old.md", bs "Link [Other](./other.md) and ![img](assets/x.png).\n")
                        , ("a/other.md", bs "Back [Old](./old.md).\n")
                        ]
                    result = DocumentLinks.planPageMove ("a/old.md", "b/old.md") pages
                lookup "b/old.md" result
                    `shouldBe` Just (bs "Link [Other](../a/other.md) and ![img](assets/x.png).\n")
                lookup "a/other.md" result
                    `shouldBe` Just (bs "Back [Old](../b/old.md).\n")

            it "given a same-folder rename, when the move is planned, then the page's own links are untouched and inbound links are fixed" $ do
                let pages =
                        [ ("a/old.md", bs "Self [Sib](./sib.md) and ![img](assets/x.png).\n")
                        , ("a/sib.md", bs "To [Old](./old.md).\n")
                        ]
                    result = DocumentLinks.planPageMove ("a/old.md", "a/new.md") pages
                lookup "a/new.md" result `shouldBe` Nothing
                lookup "a/sib.md" result `shouldBe` Just (bs "To [Old](./new.md).\n")

        describe "assetNamesIn" $ do
            it "given body links and images, when asset names are extracted, then the asset basenames are returned" $ do
                DocumentLinks.assetNamesIn (bs "![d](assets/diagram.png) and [f](./assets/report.pdf) and [x](./other.md)")
                    `shouldBe` ["diagram.png", "report.pdf"]

        describe "classifyAssets" $ do
            it "given assets some peers reference and some do not, when classified, then the referenced ones are shared and the rest exclusive" $ do
                DocumentLinks.classifyAssets ["a.png", "b.png"] [["a.png"], ["c.png"]]
                    `shouldBe` [("a.png", DocumentLinks.SharedAsset), ("b.png", DocumentLinks.ExclusiveAsset)]

        describe "referrersMatching" $ do
            it "given pages linking to a target, when referrers are matched, then each is returned with its raw link and the excluded pages omitted" $ do
                let pages =
                        [ ("a/index.md", bs "Card [P](./p.md)\n")
                        , ("a/other.md", bs "See [P](./p.md) twice [P](./p.md#x)\n")
                        , ("a/p.md", bs "self [me](./p.md)\n")
                        ]
                DocumentLinks.referrersMatching (== "a/p.md") ["a/index.md", "a/p.md"] pages
                    `shouldBe` [("a/other.md", "./p.md"), ("a/other.md", "./p.md#x")]

            it "given a subtree predicate for a section delete, when referrers are matched, then the pages linking into the subtree are returned" $ do
                let pages =
                        [ ("top.md", bs "Into [X](./sec/sub/x.md)\n")
                        , ("sec/inside.md", bs "Sibling [Y](./y.md)\n")
                        ]
                    inSubtree t = t == "sec" || ("sec/" `List.isPrefixOf` t)
                DocumentLinks.referrersMatching inSubtree ["sec/inside.md"] pages
                    `shouldBe` [("top.md", "./sec/sub/x.md")]
