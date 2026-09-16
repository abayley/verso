{- | The derived-index maintenance seam (RFC-0048). A structural operation
(RFC-0045) or a content save notifies the derived indexes -- the link index
(RFC-0029) and the search index (RFC-0034) -- of what changed by emitting an
'Event' to a 'Maintenance' handler. One handler replaces the earlier record of
five hooks: a new kind of change is one constructor and one case arm per adapter,
and a test records the events a transaction emits, in order, without an index.

The event carries the rendered tree path, matching the index and search consumers,
which are string-based; the emitter renders its 'Verso.TreePath.TreePath' at the
point of emission.
-}
module Verso.Maintenance (
    Event (..),
    Maintenance,
    none,
    combine,
) where

-- | A change the derived indexes must be told about: a move (from, to), a delete, a create, a restore, or a content save. Paths are rendered tree paths.
data Event
    = Moved String String
    | Deleted String
    | Created String
    | Restored String
    | Saved String
    deriving (Eq, Show)

-- | How a change is applied to the derived indexes: the handler run for each 'Event'.
type Maintenance = Event -> IO ()

-- | The no-op handler, used when no index is attached (tests, scan mode).
none :: Maintenance
none _ = pure ()

-- | Runs two handlers for each event (the link index, then search).
combine :: Maintenance -> Maintenance -> Maintenance
combine a b event = a event >> b event
