{- | The link index's freshness fingerprint (RFC-0029): a @(path, mtime, size)@ tuple
over every @.md@ in the document tree, held alongside the graph so the server can
cheaply detect an out-of-band change before relying on the index. Before a move/delete
the server re-fingerprints the tree and compares: an equal fingerprint means the graph
is provably consistent with the filesystem, an unequal one means rebuild first
(ADR-067).

The walk ('markdownFiles') enumerates the same @.md@ pages the whole-tree scan
considers -- skipping dot-entries and the @assets@/@meta@ folders, exactly as
'Verso.TreeMove.enumerateRelevant' does -- so the fingerprint and the graph cover
the same file set. 'markdownFiles' is shared with the index build (RFC-0029 phase 3),
which reads each file's body while the fingerprint stats it, so a single walk feeds
both.
-}
module Verso.LinkFingerprint (
    Fingerprint,
    markdownFiles,
    fingerprintTree,
) where

import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory

-- | The tree's freshness fingerprint: each @.md@ tree path to its modification time and size.
type Fingerprint = Map.Map String FileSystem.FileStat

{- | Every @.md@ file in the tree as @(treeRelPath, filesystemPath)@, skipping
dot-entries and the @assets@/@meta@ folders (mirroring
'Verso.TreeMove.enumerateRelevant'). Filesystem paths are built from the walk, not
re-resolved, since they come from @listDirectory@ rather than untrusted input.
-}
markdownFiles :: FilePath -> IO [(String, FilePath)]
markdownFiles = walk ""
  where
    walk rel dirFs = do
        names <- Directory.listDirectory dirFs
        fmap concat (mapM (collect rel dirFs) names)
    collect rel dirFs name
        | isDot name = pure []
        | otherwise = do
            let childRel = joinRel rel name
                childFs = dirFs ++ "/" ++ name
            isDir <- Directory.doesDirectoryExist childFs
            if isDir
                then if name == "assets" || name == "meta" then pure [] else walk childRel childFs
                else pure [(childRel, childFs) | ".md" `List.isSuffixOf` name]
    isDot ('.' : _) = True
    isDot _ = False
    joinRel "" s = s
    joinRel p s = p ++ "/" ++ s

{- | Fingerprints the tree: stats every @.md@ and maps its tree path to the result. A
file that vanishes between the walk and the @stat@ is dropped (the next operation's
re-fingerprint sees the change and rebuilds).
-}
fingerprintTree :: FilePath -> IO Fingerprint
fingerprintTree root = do
    files <- markdownFiles root
    entries <- mapM stat1 files
    pure (Map.fromList (Maybe.catMaybes entries))
  where
    stat1 (rel, fs) = fmap (fmap (withPath rel)) (FileSystem.fileStat fs)
    withPath rel st = (rel, st)
