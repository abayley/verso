{- | Result fusion for the Concordance search engine (RFC-0034). The engine
performs hybrid fusion natively (LanceDB's reciprocal rank fusion), so
'rrf' here is the pure fallback seam should that path ever be unavailable;
'groupByPage' is used on every search to collapse chunk hits into one
result per page.
-}
module Concordance.Fuse (
    rrf,
    groupByPage,
) where

import qualified Concordance.Store as Store
import qualified Data.List as List
import qualified Data.Map.Strict as Map

{- | Reciprocal rank fusion: each list contributes @1 / (k + rank)@ per
member (rank is 1-based); members are returned by descending fused score.
-}
rrf :: Int -> [[String]] -> [(String, Double)]
rrf k ranked =
    List.sortBy (\(_, a) (_, b) -> compare b a) (Map.toList scores)
  where
    scores =
        Map.fromListWith
            (+)
            [ (member, 1 / fromIntegral (k + rank))
            | list <- ranked
            , (rank, member) <- zip [1 :: Int ..] list
            ]

{- | Collapses ranked chunk hits to one hit per page -- the page's
best-ranked chunk -- preserving the incoming (already ranked) order.
-}
groupByPage :: [Store.Hit] -> [Store.Hit]
groupByPage = go []
  where
    go _ [] = []
    go seen (h : hs)
        | Store.hitPage h `elem` seen = go seen hs
        | otherwise = h : go (Store.hitPage h : seen) hs
