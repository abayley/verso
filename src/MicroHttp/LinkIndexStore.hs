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
) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map as Map
import MicroHttp.FileOps (fileStat)
import MicroHttp.LinkFingerprint (Fingerprint, fingerprintTree, markdownFiles)
import MicroHttp.LinkIndex (LinkIndex, buildIndex)
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
        body <- readBody fs
        st <- fileStat fs
        pure (rel, body, st)
    readBody fs = do
        exists <- doesFileExist fs
        if exists then fmap (Just . BS.unpack) (BS.readFile fs) else pure Nothing
