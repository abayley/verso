module Verso.LinkIndexSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import Test.Hspec
import qualified Verso.DocumentLinks as DocumentLinks
import qualified Verso.LinkIndex as LinkIndex

-- | A page body as bytes (the index/link engine works over 'ByteString', RFC-0029).
bs :: String -> BS.ByteString
bs = BS.pack

{- | A small document tree as @(treePath, body)@ pairs, with the in-tree cross-links
the index and the scan must agree on. Links are @.md@ page links (the graph) plus one
same-folder asset reference (excluded from the graph, ADR-0066).
-}
pages :: [(String, BS.ByteString)]
pages =
    [ ("index.md", bs "- [Guide](./guide/index.md)\n- [Reference](./ref/index.md)\n")
    , ("guide/index.md", bs "[Intro](./intro.md) [Setup](./setup.md) [API](../ref/api.md)\n")
    , ("guide/intro.md", bs "[Setup](./setup.md) and [API](../ref/api.md)\n")
    , ("guide/setup.md", bs "back to [Intro](./intro.md)\n")
    , ("ref/index.md", bs "- [API](./api.md)\n")
    , ("ref/api.md", bs "see [Intro](../guide/intro.md) ![d](assets/diagram.png)\n")
    ]

-- | A subtree-membership predicate for a section path (the section and its descendants).
inSubtree :: String -> String -> Bool
inSubtree prefix target = target == prefix || (prefix ++ "/") `isPrefixOf` target

isPrefixOf :: String -> String -> Bool
isPrefixOf [] _ = True
isPrefixOf _ [] = False
isPrefixOf (x : xs) (y : ys) = x == y && isPrefixOf xs ys

spec :: Spec
spec =
    describe "Verso.LinkIndex" $ do
        describe "buildIndex" $ do
            it "given pages linking to other pages and to assets, when the index is built, then only the resolved in-tree .md targets are recorded" $ do
                let ix = LinkIndex.buildIndex pages
                List.sort (LinkIndex.outboundOf "guide/index.md" ix)
                    `shouldBe` List.sort ["guide/intro.md", "guide/setup.md", "ref/api.md"]
                -- the asset reference is not an edge
                List.sort (LinkIndex.outboundOf "ref/api.md" ix) `shouldBe` ["guide/intro.md"]

            it "given a set of pages, when the index is built, then the graph is inverted into a referrer map" $ do
                let ix = LinkIndex.buildIndex pages
                List.sort (LinkIndex.inboundOf "ref/api.md" ix)
                    `shouldBe` List.sort ["guide/index.md", "guide/intro.md", "ref/index.md"]
                List.sort (LinkIndex.inboundOf "guide/intro.md" ix)
                    `shouldBe` List.sort ["guide/index.md", "guide/setup.md", "ref/api.md"]

            it "given a never-linked page and an asset target, when the index is built, then neither has an inbound entry" $ do
                let ix = LinkIndex.buildIndex pages
                LinkIndex.inboundOf "assets/diagram.png" ix `shouldBe` []
                LinkIndex.inboundOf "index.md" ix `shouldBe` []

        describe "updatePage" $ do
            it "given a page whose links change, when it is updated, then the inverse is patched" $ do
                let ix = LinkIndex.updatePage "guide/setup.md" (bs "now links [API](../ref/api.md)\n") (LinkIndex.buildIndex pages)
                -- setup no longer links to intro, now links to api
                List.sort (LinkIndex.inboundOf "guide/intro.md" ix) `shouldBe` List.sort ["guide/index.md", "ref/api.md"]
                List.sort (LinkIndex.inboundOf "ref/api.md" ix)
                    `shouldBe` List.sort ["guide/index.md", "guide/intro.md", "guide/setup.md", "ref/index.md"]

            it "given a series of incremental updates, when compared with a rebuild, then the two indexes agree" $ do
                let incremental =
                        LinkIndex.updatePage "ref/api.md" (bs "[Guide](../guide/index.md)\n") $
                            LinkIndex.updatePage "guide/setup.md" (bs "[API](../ref/api.md)\n") (LinkIndex.buildIndex pages)
                    rebuilt =
                        LinkIndex.buildIndex
                            ( ("guide/setup.md", bs "[API](../ref/api.md)\n")
                                : ("ref/api.md", bs "[Guide](../guide/index.md)\n")
                                : filter ((`notElem` ["guide/setup.md", "ref/api.md"]) . fst) pages
                            )
                incremental `shouldBe` rebuilt

        describe "removePage" $ do
            it "given an indexed page, when it is removed, then its outbound edges leave the inverse" $ do
                let ix = LinkIndex.removePage "guide/intro.md" (LinkIndex.buildIndex pages)
                LinkIndex.outboundOf "guide/intro.md" ix `shouldBe` []
                -- intro's outbound edges withdrawn, but guide/index.md still links to setup and api
                List.sort (LinkIndex.inboundOf "guide/setup.md" ix) `shouldBe` ["guide/index.md"]
                List.sort (LinkIndex.inboundOf "ref/api.md" ix) `shouldBe` List.sort ["guide/index.md", "ref/index.md"]

            it "given a page removed from the index, when compared with a rebuild omitting it, then the two agree" $ do
                let removed = LinkIndex.removePage "guide/intro.md" (LinkIndex.buildIndex pages)
                    rebuilt = LinkIndex.buildIndex (filter ((/= "guide/intro.md") . fst) pages)
                removed `shouldBe` rebuilt

        describe "relocatePage" $ do
            it "given a moved page, when it is relocated, then it is re-keyed to its new path and body" $ do
                let ix =
                        LinkIndex.relocatePage
                            "guide/intro.md"
                            "ref/intro.md"
                            (bs "[Setup](../guide/setup.md) [API](./api.md)\n")
                            (LinkIndex.buildIndex pages)
                LinkIndex.outboundOf "guide/intro.md" ix `shouldBe` []
                List.sort (LinkIndex.outboundOf "ref/intro.md" ix)
                    `shouldBe` List.sort ["guide/setup.md", "ref/api.md"]
                List.sort (LinkIndex.inboundOf "ref/api.md" ix)
                    `shouldBe` List.sort ["guide/index.md", "ref/index.md", "ref/intro.md"]

        describe "relocateIndex" $ do
            it "given a relocated index, when compared with a rebuild from the relocated edges, then the two agree" $ do
                let ix = LinkIndex.buildIndex pages
                    reloc p = Maybe.fromMaybe p (DocumentLinks.relocatePath "guide" "ref/guide" p)
                    oracle = LinkIndex.indexFromEdges [(reloc p, map reloc ts) | (p, ts) <- LinkIndex.outboundEdges ix]
                LinkIndex.relocateIndex "guide" "ref/guide" ix `shouldBe` oracle

        describe "referrers (agrees with referrersMatching)" $ do
            it "given a page delete target, when its referrers are queried, then the linking pages are returned" $ do
                let ix = LinkIndex.buildIndex pages
                    matches = (== "ref/api.md")
                    excluded = ["ref/index.md", "ref/api.md"]
                List.sort (LinkIndex.referrers matches excluded ix)
                    `shouldBe` List.sort (dedup (map fst (DocumentLinks.referrersMatching matches excluded (linksOf pages))))

            it "given a section delete subtree, when its referrers are queried, then the pages linking into it are returned" $ do
                let ix = LinkIndex.buildIndex pages
                    matches = inSubtree "ref"
                    excluded = "index.md" : ["ref/index.md", "ref/api.md"]
                List.sort (LinkIndex.referrers matches excluded ix)
                    `shouldBe` List.sort (dedup (map fst (DocumentLinks.referrersMatching matches excluded (linksOf pages))))

        describe "rewriteCandidates (agrees with planMoveRewrites)" $ do
            it "given a planned move, when candidates are drawn from the index, then they include every page the byte scan would rewrite" $ do
                let ix = LinkIndex.buildIndex pages
                    move = ("guide", "ref/guide")
                    candidates = LinkIndex.rewriteCandidates (inSubtree "guide") ix
                    candidatePages = filter ((`elem` candidates) . fst) pages
                List.sort (map fst (DocumentLinks.planMoveRewrites move (linksOf candidatePages)))
                    `shouldBe` List.sort (map fst (DocumentLinks.planMoveRewrites move (linksOf pages)))

-- | Pages reduced to their links, as the scan-side functions now take them.
linksOf :: [(String, BS.ByteString)] -> [(String, [DocumentLinks.Link])]
linksOf pages = [(p, DocumentLinks.pageLinks b) | (p, b) <- pages]

-- | Order-independent dedup (the index returns a page set; the scan returns a row per link).
dedup :: [String] -> [String]
dedup = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) = if x `elem` seen then go seen xs else go (x : seen) xs
