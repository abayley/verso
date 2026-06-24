{- | The running server's in-memory home for the link index (RFC-0029 phase 3): an
'MVar' holding the graph ('MicroHttp.LinkIndex') and the freshness fingerprint
('MicroHttp.LinkFingerprint') it was built from, with the per-operation freshness check
that keeps it correct (ADR-067).

The index is built __lazily on first use__ (startup stays instant; many sessions never
move or delete). 'freshIndex' is the accessor a correctness-critical operation calls:
it re-stats the tree (a cheap @stat@ pass) and compares to the stored fingerprint --
on a match the graph is provably consistent with the filesystem and is served as is, on
a mismatch (an out-of-band edit, or the first use) it rebuilds the graph and
fingerprint from the tree first. The 'MVar' serialises the check-and-rebuild against the
server's concurrent connection handlers, exactly as 'MicroHttp.Log' serialises its
rotation.

Build reads each page's body for the graph and stats it for the fingerprint in a single
tree walk ('markdownFiles'), so a rebuild is one pass, not two.
-}
module MicroHttp.LinkIndexStore (
    LinkIndexStore,
    newLinkIndexStore,
    freshIndex,
    resync,
) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Monad (foldM)
import qualified Data.ByteString.Char8 as BS
import Data.List (foldl')
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import MicroHttp.FileOps (fileStat)
import MicroHttp.LinkFingerprint (Fingerprint, fingerprintTree, markdownFiles)
import MicroHttp.LinkIndex (LinkIndex, buildIndex, removePage, updatePage)
import System.Directory (doesFileExist)

-- | The graph and the fingerprint of the tree it was built from, held together.
data IndexState = IndexState
    { stIndex :: LinkIndex
    , stFingerprint :: Fingerprint
    }

{- | A handle to the server's link index. 'Nothing' until the first 'freshIndex' builds
it (lazy build); thereafter the last-built graph and its fingerprint.
-}
newtype LinkIndexStore = LinkIndexStore (MVar (Maybe IndexState))

-- | A fresh, unbuilt store (the build is deferred to the first 'freshIndex').
newLinkIndexStore :: IO LinkIndexStore
newLinkIndexStore = fmap LinkIndexStore (newMVar Nothing)

{- | The current index, rebuilt first if the tree changed out-of-band (or on first
use). Re-stats the tree and compares to the stored fingerprint: trusts the cached graph
on a match, rebuilds graph and fingerprint on a mismatch. The 'Bool' reports whether a
(re)build happened, for the caller's drift logging (ADR-067). Serialised through the
'MVar', so a concurrent operation sees a consistent index.
-}
freshIndex :: FilePath -> LinkIndexStore -> IO (Bool, LinkIndex)
freshIndex root (LinkIndexStore mv) =
    modifyMVar mv $ \mState -> do
        current <- fingerprintTree root
        case mState of
            Just st
                | stFingerprint st == current -> pure (mState, (False, stIndex st))
            _ -> do
                fresh <- buildFromTree root
                pure (Just fresh, (True, stIndex fresh))

{- | Builds the graph and fingerprint from the tree in a single walk: every @.md@'s
body feeds 'buildIndex' and its @stat@ feeds the fingerprint. A file that vanishes
between the walk and the read/stat is omitted (the next operation's check rebuilds).
-}
buildFromTree :: FilePath -> IO IndexState
buildFromTree root = do
    files <- markdownFiles root
    entries <- mapM readAndStat files
    let pages = [(rel, body) | (rel, Just body, _) <- entries]
        fingerprint = Map.fromList [(rel, st) | (rel, _, Just st) <- entries]
    pure (IndexState (buildIndex pages) fingerprint)
  where
    readAndStat (rel, fs) = do
        body <- readPageBody fs
        st <- fileStat fs
        pure (rel, body, st)

{- | Re-syncs the held index to the tree __incrementally__ after an in-server mutation
(RFC-0029 phase 5): re-fingerprints, then patches the graph for exactly the paths whose
fingerprint changed -- re-reading a modified/added page (via 'updatePage'), dropping a
removed one (via 'removePage') -- and stores the new fingerprint. Because the fingerprint
is updated in lockstep with the writes, the next 'freshIndex' matches and does not see
the server's own change as out-of-band drift; the patched graph equals a full rebuild
(the anti-drift invariant). A no-op before the first build (the first 'freshIndex' builds).
-}
resync :: FilePath -> LinkIndexStore -> IO ()
resync root (LinkIndexStore mv) = modifyMVar_ mv (resyncState root)

-- | The incremental re-sync of one held state (a no-op before the first build).
resyncState :: FilePath -> Maybe IndexState -> IO (Maybe IndexState)
resyncState _ Nothing = pure Nothing
resyncState root (Just state) = do
    current <- fingerprintTree root
    let old = stFingerprint state
        changed = [rel | (rel, fp) <- Map.toList current, Map.lookup rel old /= Just fp]
        removed = [rel | rel <- Map.keys old, not (Map.member rel current)]
    patched <- foldM (patchPage root) (stIndex state) changed
    let pruned = foldl' (flip removePage) patched removed
    pure (Just (IndexState pruned current))

-- | Patches one modified/added page into the graph by re-reading its current body.
patchPage :: FilePath -> LinkIndex -> String -> IO LinkIndex
patchPage root index rel = do
    body <- readPageBody (root ++ "/" ++ rel)
    pure (updatePage rel (fromMaybe "" body) index)

-- | Reads a page body as a 'String', or 'Nothing' when the file is absent.
readPageBody :: FilePath -> IO (Maybe String)
readPageBody fs = do
    exists <- doesFileExist fs
    if exists then fmap (Just . BS.unpack) (BS.readFile fs) else pure Nothing
