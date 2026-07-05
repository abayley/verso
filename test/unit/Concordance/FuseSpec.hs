module Concordance.FuseSpec (spec) where

import qualified Concordance.Fuse as Fuse
import qualified Concordance.Store as Store
import Test.Hspec

hit :: String -> Int -> Store.Hit
hit page n = Store.Hit page ("h" ++ show n) n 0.5 "text"

spec :: Spec
spec =
    describe "Concordance.Fuse" $ do
        it "ranks a member shared by both lists above equal-rank singletons" $ do
            let fused = Fuse.rrf 60 [["a", "b", "c"], ["b", "d"]]
            map fst fused `shouldBe` ["b", "a", "d", "c"]

        it "preserves the other list's order when one side is empty" $ do
            let fused = Fuse.rrf 60 [["x", "y", "z"], []]
            map fst fused `shouldBe` ["x", "y", "z"]

        it "groups ranked hits to one per page, keeping the best chunk" $ do
            let hits = [hit "a.md" 0, hit "b.md" 1, hit "a.md" 2, hit "c.md" 0]
            map Store.hitAnchor (Fuse.groupByPage hits)
                `shouldBe` ["h0", "h1", "h0"]
            map Store.hitPage (Fuse.groupByPage hits)
                `shouldBe` ["a.md", "b.md", "c.md"]
