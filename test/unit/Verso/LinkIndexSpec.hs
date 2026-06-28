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
same-folder asset reference (excluded from the graph, ADR-066).
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
            it "records each page's resolved in-tree .md link targets (no asset edges)" $ do
                let ix = LinkIndex.buildIndex pages
                List.sort (LinkIndex.outboundOf "guide/index.md" ix)
                    `shouldBe` List.sort ["guide/intro.md", "guide/setup.md", "ref/api.md"]
                -- the asset reference is not an edge
                List.sort (LinkIndex.outboundOf "ref/api.md" ix) `shouldBe` ["guide/intro.md"]

            it "inverts the graph into a referrer map" $ do
                let ix = LinkIndex.buildIndex pages
                List.sort (LinkIndex.inboundOf "ref/api.md" ix)
                    `shouldBe` List.sort ["guide/index.md", "guide/intro.md", "ref/index.md"]
                List.sort (LinkIndex.inboundOf "guide/intro.md" ix)
                    `shouldBe` List.sort ["guide/index.md", "guide/setup.md", "ref/api.md"]

            it "yields no inbound entry for a never-linked or asset target" $ do
                let ix = LinkIndex.buildIndex pages
                LinkIndex.inboundOf "assets/diagram.png" ix `shouldBe` []
                LinkIndex.inboundOf "index.md" ix `shouldBe` []

        describe "updatePage" $ do
            it "patches the inverse when a page's links change" $ do
                let ix = LinkIndex.updatePage "guide/setup.md" (bs "now links [API](../ref/api.md)\n") (LinkIndex.buildIndex pages)
                -- setup no longer links to intro, now links to api
                List.sort (LinkIndex.inboundOf "guide/intro.md" ix) `shouldBe` List.sort ["guide/index.md", "ref/api.md"]
                List.sort (LinkIndex.inboundOf "ref/api.md" ix)
                    `shouldBe` List.sort ["guide/index.md", "guide/intro.md", "guide/setup.md", "ref/index.md"]

            it "rebuilds equal to incremental updates (no drift)" $ do
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
            it "drops the page's outbound edges from the inverse" $ do
                let ix = LinkIndex.removePage "guide/intro.md" (LinkIndex.buildIndex pages)
                LinkIndex.outboundOf "guide/intro.md" ix `shouldBe` []
                -- intro's outbound edges withdrawn, but guide/index.md still links to setup and api
                List.sort (LinkIndex.inboundOf "guide/setup.md" ix) `shouldBe` ["guide/index.md"]
                List.sort (LinkIndex.inboundOf "ref/api.md" ix) `shouldBe` List.sort ["guide/index.md", "ref/index.md"]

            it "equals a rebuild without the removed page as a source" $ do
                let removed = LinkIndex.removePage "guide/intro.md" (LinkIndex.buildIndex pages)
                    rebuilt = LinkIndex.buildIndex (filter ((/= "guide/intro.md") . fst) pages)
                removed `shouldBe` rebuilt

        describe "relocatePage" $ do
            it "re-keys a moved page to its new path and body" $ do
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
            it "equals a rebuild from the relocated edges (no drift)" $ do
                let ix = LinkIndex.buildIndex pages
                    reloc p = Maybe.fromMaybe p (DocumentLinks.relocatePath "guide" "ref/guide" p)
                    oracle = LinkIndex.indexFromEdges [(reloc p, map reloc ts) | (p, ts) <- LinkIndex.outboundEdges ix]
                LinkIndex.relocateIndex "guide" "ref/guide" ix `shouldBe` oracle

        describe "referrers (agrees with referrersMatching)" $ do
            it "finds the referrers of a page delete target" $ do
                let ix = LinkIndex.buildIndex pages
                    matches = (== "ref/api.md")
                    excluded = ["ref/index.md", "ref/api.md"]
                List.sort (LinkIndex.referrers matches excluded ix)
                    `shouldBe` List.sort (dedup (map fst (DocumentLinks.referrersMatching matches excluded pages)))

            it "finds the referrers into a section delete subtree" $ do
                let ix = LinkIndex.buildIndex pages
                    matches = inSubtree "ref"
                    excluded = "index.md" : ["ref/index.md", "ref/api.md"]
                List.sort (LinkIndex.referrers matches excluded ix)
                    `shouldBe` List.sort (dedup (map fst (DocumentLinks.referrersMatching matches excluded pages)))

        describe "rewriteCandidates (agrees with planMoveRewrites)" $ do
            it "is a superset that drops no page planMoveRewrites changes" $ do
                let ix = LinkIndex.buildIndex pages
                    move = ("guide", "ref/guide")
                    candidates = LinkIndex.rewriteCandidates (inSubtree "guide") ix
                    candidatePages = filter ((`elem` candidates) . fst) pages
                List.sort (map fst (DocumentLinks.planMoveRewrites move candidatePages))
                    `shouldBe` List.sort (map fst (DocumentLinks.planMoveRewrites move pages))

-- | Order-independent dedup (the index returns a page set; the scan returns a row per link).
dedup :: [String] -> [String]
dedup = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) = if x `elem` seen then go seen xs else go (x : seen) xs
