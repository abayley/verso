{- | The re-index queue's pure state (RFC-0034 decision 4): a coalescing
pending set of page paths plus the page in flight. Enqueueing an
already-pending page is a no-op; re-enqueueing the in-flight page marks it
dirty, so it drains again after the current pass. The worker's IO loop
lives in "Verso.SearchIndex"; this module is the testable transition logic.
-}
module Verso.SearchQueue (
    Queue,
    emptyQueue,
    enqueue,
    startNext,
    finish,
    queueDepth,
    optimiseDue,
) where

-- | The queue state: ordered pending pages, the in-flight page, dirtiness.
data Queue = Queue
    { queuePending :: [String]
    , queueInFlight :: Maybe String
    , queueDirty :: Bool
    }
    deriving (Eq, Show)

-- | The idle queue.
emptyQueue :: Queue
emptyQueue = Queue [] Nothing False

-- | Adds a page, coalescing repeats and dirty-marking the in-flight page.
enqueue :: String -> Queue -> Queue
enqueue page q
    | queueInFlight q == Just page = q{queueDirty = True}
    | page `elem` queuePending q = q
    | otherwise = q{queuePending = queuePending q ++ [page]}

{- | Takes the next page to process, recording it as in flight. 'Nothing'
when the queue is idle (any in-flight page must be finished first).
-}
startNext :: Queue -> (Maybe String, Queue)
startNext q =
    case (queueInFlight q, queuePending q) of
        (Nothing, page : rest) ->
            (Just page, q{queuePending = rest, queueInFlight = Just page})
        _ -> (Nothing, q)

{- | Completes the in-flight page; a dirty page (re-enqueued while in
flight) returns to the back of the pending set.
-}
finish :: Queue -> Queue
finish q =
    case queueInFlight q of
        Just page
            | queueDirty q ->
                enqueue page q{queueInFlight = Nothing, queueDirty = False}
        _ -> q{queueInFlight = Nothing, queueDirty = False}

-- | Pages awaiting or undergoing re-indexing (drives the results note).
queueDepth :: Queue -> Int
queueDepth q =
    length (queuePending q) + maybe 0 (const 1) (queueInFlight q)

{- | Whether the store should be optimised now, given the writes since the
last optimisation and whether the queue has just drained. LanceDB fragments
under the delete-then-add upserts, and optimisation also folds fresh rows
into the vector and FTS indexes. Normal operation (a save, a move's sweep)
optimises as soon as the queue drains; a bulk backlog (first indexing, a
migration re-export) optimises in batches along the way.
-}
optimiseDue :: Int -> Bool -> Bool
optimiseDue writesSince queueEmpty
    | writesSince <= 0 = False
    | queueEmpty = True
    | otherwise = writesSince >= optimiseBatch

-- | Writes tolerated between optimisations while the queue stays busy.
optimiseBatch :: Int
optimiseBatch = 256
