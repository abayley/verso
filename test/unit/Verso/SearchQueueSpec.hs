module Verso.SearchQueueSpec (spec) where

import Test.Hspec
import qualified Verso.SearchQueue as SearchQueue

spec :: Spec
spec =
    describe "Verso.SearchQueue" $ do
        it "given a page enqueued twice, when the queue drains, then it is handed out once" $ do
            let q =
                    SearchQueue.enqueue "a.md" $
                        SearchQueue.enqueue "a.md" SearchQueue.emptyQueue
                (next, q') = SearchQueue.startNext q
            next `shouldBe` Just "a.md"
            fst (SearchQueue.startNext (SearchQueue.finish q'))
                `shouldBe` Nothing

        it "given a page arriving while the same page is in flight, when the queue drains again, then it is handed out a second time" $ do
            let (started, q) =
                    SearchQueue.startNext
                        (SearchQueue.enqueue "a.md" SearchQueue.emptyQueue)
                q' = SearchQueue.enqueue "a.md" q
                (again, _) = SearchQueue.startNext (SearchQueue.finish q')
            started `shouldBe` Just "a.md"
            -- in flight: not handed out a second time concurrently
            fst (SearchQueue.startNext q') `shouldBe` Nothing
            again `shouldBe` Just "a.md"

        it "given writes with an emptied queue and then a full batch, when the queue is drained, then optimisation is asked for in both cases" $ do
            -- normal operation: any writes + an empty queue optimise at once
            SearchQueue.optimiseDue 1 True `shouldBe` True
            -- bulk indexing: optimise in batches while the queue is busy
            SearchQueue.optimiseDue 255 False `shouldBe` False
            SearchQueue.optimiseDue 256 False `shouldBe` True
            -- nothing written: nothing to optimise
            SearchQueue.optimiseDue 0 True `shouldBe` False

        it "given pending and in-flight pages, when the depth is read, then it counts both" $ do
            let q0 = SearchQueue.enqueue "b.md" (SearchQueue.enqueue "a.md" SearchQueue.emptyQueue)
                (_, q1) = SearchQueue.startNext q0
            SearchQueue.queueDepth q0 `shouldBe` 2
            SearchQueue.queueDepth q1 `shouldBe` 2
            SearchQueue.queueDepth (SearchQueue.finish q1) `shouldBe` 1
