module Verso.SearchQueueSpec (spec) where

import Test.Hspec
import qualified Verso.SearchQueue as SearchQueue

spec :: Spec
spec =
    describe "Verso.SearchQueue" $ do
        it "coalesces: a page enqueued twice drains once" $ do
            let q =
                    SearchQueue.enqueue "a.md" $
                        SearchQueue.enqueue "a.md" SearchQueue.emptyQueue
                (next, q') = SearchQueue.startNext q
            next `shouldBe` Just "a.md"
            fst (SearchQueue.startNext (SearchQueue.finish q'))
                `shouldBe` Nothing

        it "re-enqueues a page that arrives while it is in flight" $ do
            let (started, q) =
                    SearchQueue.startNext
                        (SearchQueue.enqueue "a.md" SearchQueue.emptyQueue)
                q' = SearchQueue.enqueue "a.md" q
                (again, _) = SearchQueue.startNext (SearchQueue.finish q')
            started `shouldBe` Just "a.md"
            -- in flight: not handed out a second time concurrently
            fst (SearchQueue.startNext q') `shouldBe` Nothing
            again `shouldBe` Just "a.md"

        it "reports depth as pending plus in-flight" $ do
            let q0 = SearchQueue.enqueue "b.md" (SearchQueue.enqueue "a.md" SearchQueue.emptyQueue)
                (_, q1) = SearchQueue.startNext q0
            SearchQueue.queueDepth q0 `shouldBe` 2
            SearchQueue.queueDepth q1 `shouldBe` 2
            SearchQueue.queueDepth (SearchQueue.finish q1) `shouldBe` 1
