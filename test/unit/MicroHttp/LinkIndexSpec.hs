module MicroHttp.LinkIndexSpec (spec) where

import Data.List (sort)
import MicroHttp.DocumentLinks (planMoveRewrites, referrersMatching)
import MicroHttp.LinkIndex (
    buildIndex,
    inboundOf,
    outboundOf,
    referrers,
    relocatePage,
    removePage,
    rewriteCandidates,
    updatePage,
 )
import Test.Hspec

{- | A small document tree as @(treePath, body)@ pairs, with the in-tree cross-links
the index and the scan must agree on. Links are @.md@ page links (the graph) plus one
same-folder asset reference (excluded from the graph, ADR-066).
-}
pages :: [(String, String)]
pages =
    [ ("index.md", "- [Guide](./guide/index.md)\n- [Reference](./ref/index.md)\n")
    , ("guide/index.md", "[Intro](./intro.md) [Setup](./setup.md) [API](../ref/api.md)\n")
    , ("guide/intro.md", "[Setup](./setup.md) and [API](../ref/api.md)\n")
    , ("guide/setup.md", "back to [Intro](./intro.md)\n")
    , ("ref/index.md", "- [API](./api.md)\n")
    , ("ref/api.md", "see [Intro](../guide/intro.md) ![d](assets/diagram.png)\n")
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
    describe "MicroHttp.LinkIndex" $ do
        describe "buildIndex" $ do
            it "records each page's resolved in-tree .md link targets (no asset edges)" $ do
                let ix = buildIndex pages
                sort (outboundOf "guide/index.md" ix)
                    `shouldBe` sort ["guide/intro.md", "guide/setup.md", "ref/api.md"]
                -- the asset reference is not an edge
                sort (outboundOf "ref/api.md" ix) `shouldBe` ["guide/intro.md"]

            it "inverts the graph into a referrer map" $ do
                let ix = buildIndex pages
                sort (inboundOf "ref/api.md" ix)
                    `shouldBe` sort ["guide/index.md", "guide/intro.md", "ref/index.md"]
                sort (inboundOf "guide/intro.md" ix)
                    `shouldBe` sort ["guide/index.md", "guide/setup.md", "ref/api.md"]

            it "yields no inbound entry for a never-linked or asset target" $ do
                let ix = buildIndex pages
                inboundOf "assets/diagram.png" ix `shouldBe` []
                inboundOf "index.md" ix `shouldBe` []

        describe "updatePage" $ do
            it "patches the inverse when a page's links change" $ do
                let ix = updatePage "guide/setup.md" "now links [API](../ref/api.md)\n" (buildIndex pages)
                -- setup no longer links to intro, now links to api
                sort (inboundOf "guide/intro.md" ix) `shouldBe` sort ["guide/index.md", "ref/api.md"]
                sort (inboundOf "ref/api.md" ix)
                    `shouldBe` sort ["guide/index.md", "guide/intro.md", "guide/setup.md", "ref/index.md"]

            it "rebuilds equal to incremental updates (no drift)" $ do
                let incremental =
                        updatePage "ref/api.md" "[Guide](../guide/index.md)\n" $
                            updatePage "guide/setup.md" "[API](../ref/api.md)\n" (buildIndex pages)
                    rebuilt =
                        buildIndex
                            ( ("guide/setup.md", "[API](../ref/api.md)\n")
                                : ("ref/api.md", "[Guide](../guide/index.md)\n")
                                : filter ((`notElem` ["guide/setup.md", "ref/api.md"]) . fst) pages
                            )
                incremental `shouldBe` rebuilt

        describe "removePage" $ do
            it "drops the page's outbound edges from the inverse" $ do
                let ix = removePage "guide/intro.md" (buildIndex pages)
                outboundOf "guide/intro.md" ix `shouldBe` []
                -- intro's outbound edges withdrawn, but guide/index.md still links to setup and api
                sort (inboundOf "guide/setup.md" ix) `shouldBe` ["guide/index.md"]
                sort (inboundOf "ref/api.md" ix) `shouldBe` sort ["guide/index.md", "ref/index.md"]

            it "equals a rebuild without the removed page as a source" $ do
                let removed = removePage "guide/intro.md" (buildIndex pages)
                    rebuilt = buildIndex (filter ((/= "guide/intro.md") . fst) pages)
                removed `shouldBe` rebuilt

        describe "relocatePage" $ do
            it "re-keys a moved page to its new path and body" $ do
                let ix =
                        relocatePage
                            "guide/intro.md"
                            "ref/intro.md"
                            "[Setup](../guide/setup.md) [API](./api.md)\n"
                            (buildIndex pages)
                outboundOf "guide/intro.md" ix `shouldBe` []
                sort (outboundOf "ref/intro.md" ix)
                    `shouldBe` sort ["guide/setup.md", "ref/api.md"]
                sort (inboundOf "ref/api.md" ix)
                    `shouldBe` sort ["guide/index.md", "ref/index.md", "ref/intro.md"]

        describe "referrers (agrees with referrersMatching)" $ do
            it "finds the referrers of a page delete target" $ do
                let ix = buildIndex pages
                    matches = (== "ref/api.md")
                    excluded = ["ref/index.md", "ref/api.md"]
                sort (referrers matches excluded ix)
                    `shouldBe` sort (dedup (map fst (referrersMatching matches excluded pages)))

            it "finds the referrers into a section delete subtree" $ do
                let ix = buildIndex pages
                    matches = inSubtree "ref"
                    excluded = "index.md" : ["ref/index.md", "ref/api.md"]
                sort (referrers matches excluded ix)
                    `shouldBe` sort (dedup (map fst (referrersMatching matches excluded pages)))

        describe "rewriteCandidates (agrees with planMoveRewrites)" $ do
            it "is a superset that drops no page planMoveRewrites changes" $ do
                let ix = buildIndex pages
                    move = ("guide", "ref/guide")
                    candidates = rewriteCandidates (inSubtree "guide") ix
                    candidatePages = filter ((`elem` candidates) . fst) pages
                sort (map fst (planMoveRewrites move candidatePages))
                    `shouldBe` sort (map fst (planMoveRewrites move pages))

-- | Order-independent dedup (the index returns a page set; the scan returns a row per link).
dedup :: [String] -> [String]
dedup = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) = if x `elem` seen then go seen xs else go (x : seen) xs
