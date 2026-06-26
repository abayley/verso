{- | The pure link graph for RFC-0029's in-memory link index: the document tree's
resolved @.md@->@.md@ link graph and its inverse, with the in-place update functions a
move/delete and incremental maintenance need. It reuses the RFC-0027 link engine
('MicroHttp.DocumentLinks') to resolve targets, so the index resolves a link exactly
as the whole-tree scan does; it is purely a performance layer that narrows /which/
pages an operation must process, never a second implementation of /what/ a link means
(ADR-066).

The graph holds only @.md@ link edges: external and asset references are excluded.
This rests on the corpus's folder-local asset convention (ADR-062): an asset is
referenced by a same-folder @assets/\<name\>@ token, which resolves inside the
referrer's own folder, so no page /outside/ a moved or deleted subtree links to an
asset /inside/ it. Under that convention the @.md@ graph is complete for the
whole-tree queries -- the index's 'referrers' and 'rewriteCandidates' return the same
page set the scan ('referrersMatching'/'planMoveRewrites', which resolve every link
including assets) would, while asset edges would add size for no whole-tree benefit.

Each adjacency list is deduplicated. 'outbound' lists stay in body order (both a
rebuild and an incremental update derive them from the same bytes via 'pageTargets',
so they match); the inverted 'inbound' lists are kept sorted (they accumulate across
pages in arbitrary order). Together this makes structural equality a true semantic
equality: an incrementally-maintained index equals a full rebuild from the same final
bodies (the anti-drift invariant, asserted in the tests).
-}
module MicroHttp.LinkIndex (
    LinkIndex,
    emptyIndex,
    buildIndex,
    forceIndex,
    outboundEdges,
    indexFromEdges,
    relocateIndex,
    removeSubtree,
    outboundOf,
    inboundOf,
    updatePage,
    removePage,
    relocatePage,
    referrers,
    rewriteCandidates,
) where

import Data.ByteString.Char8 (ByteString)
import Data.List (foldl', isPrefixOf, isSuffixOf, nub)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import MicroHttp.DocumentLinks (dirOfPath, linkTarget, pageLinks, relocatePath, resolveTarget)

-- | A page's tree-relative path (the body's location); a graph source.
type PagePath = String

-- | A tree-relative path a link resolves to; a graph target / inbound key.
type TreePath = String

{- | The resolved @.md@->@.md@ link graph of the document tree: each page's outbound
targets and the inverted referrer map. 'inbound' is derived from 'outbound'; both are
stored so a per-page change patches the inverse without a full rebuild.
-}
data LinkIndex = LinkIndex
    { idxOutbound :: Map PagePath [TreePath]
    , idxInbound :: Map TreePath [PagePath]
    }
    deriving (Eq, Show)

-- | The empty index (no pages, no edges).
emptyIndex :: LinkIndex
emptyIndex = LinkIndex Map.empty Map.empty

{- | Builds the index from every page as @(treePath, body)@. Equivalent to applying
'updatePage' to each page over the empty index, so an incremental sequence converges to
this rebuild.
-}
buildIndex :: [(PagePath, ByteString)] -> LinkIndex
buildIndex = foldl' (\ix (page, body) -> updatePage page body ix) emptyIndex

{- | Forces the graph's adjacency lists so the deferred link parse (the comprehension in
'pageTargets') runs /now/, where the index is built or maintained, rather than being left
a thunk for whatever first reads the graph (RFC-0029).
-}
forceIndex :: LinkIndex -> LinkIndex
forceIndex ix = edgeCount `seq` ix
  where
    edgeCount =
        sum (map length (Map.elems (idxOutbound ix)))
            + sum (map length (Map.elems (idxInbound ix)))

-- | The graph's outbound edges (every page, including linkless ones), for persistence.
outboundEdges :: LinkIndex -> [(PagePath, [TreePath])]
outboundEdges = Map.toList . idxOutbound

{- | Rebuilds the index from already-resolved outbound edges (re-deriving 'inbound'),
without re-parsing bodies. Used to load a persisted index and to relocate by prefix.
-}
indexFromEdges :: [(PagePath, [TreePath])] -> LinkIndex
indexFromEdges = foldl' addPageEdges emptyIndex
  where
    addPageEdges ix (page, targets) =
        LinkIndex
            (Map.insert page targets (idxOutbound ix))
            (foldl' (\m t -> addInbound t page m) (idxInbound ix) targets)

{- | Relocates a moved subtree within the graph (RFC-0029): renames every page key and
every resolved target that lies under @oldPrefix@ to sit under @newPrefix@. This is the
exact effect a move has on the graph -- a page at @S/x@ becomes @S'/x@ and its links into
the subtree resolve to @S'/...@ -- so a move is maintained by a pure transform, with no
re-read. Equivalent to a rebuild from the post-move bodies.
-}
relocateIndex :: String -> String -> LinkIndex -> LinkIndex
relocateIndex oldPrefix newPrefix ix =
    indexFromEdges [(reloc page, map reloc targets) | (page, targets) <- outboundEdges ix]
  where
    reloc p = fromMaybe p (relocatePath oldPrefix newPrefix p)

-- | Removes a deleted page or whole section subtree from the graph as a source (every key at or under @prefix@).
removeSubtree :: String -> LinkIndex -> LinkIndex
removeSubtree prefix ix = foldl' (flip removePage) ix underPrefix
  where
    underPrefix =
        [page | page <- Map.keys (idxOutbound ix), page == prefix || (prefix ++ "/") `isPrefixOf` page]

-- | A page's recorded outbound @.md@ targets (empty when the page is absent or linkless).
outboundOf :: PagePath -> LinkIndex -> [TreePath]
outboundOf page = Map.findWithDefault [] page . idxOutbound

-- | The pages recorded as linking to a target (empty when nothing links to it).
inboundOf :: TreePath -> LinkIndex -> [PagePath]
inboundOf target = Map.findWithDefault [] target . idxInbound

{- | A page's resolved in-tree @.md@ link targets (tree-absolute), deduplicated and in
body order. External and non-@.md@ (asset) targets are excluded -- the graph is
@.md@->@.md@ only (ADR-066). Resolution reuses 'MicroHttp.DocumentLinks', so it matches
the scan.
-}
pageTargets :: PagePath -> ByteString -> [TreePath]
pageTargets page body =
    nub
        [ target
        | link <- pageLinks body
        , Just target <- [resolveTarget (dirOfPath page) (linkTarget link)]
        , ".md" `isSuffixOf` target
        ]

{- | Records (or replaces) a page's outbound edges from its current body, patching the
inverse: the page's previous edges are withdrawn from 'inbound' and its new edges added.
Applied per page, this keeps the index equal to a rebuild from the same bodies.
-}
updatePage :: PagePath -> ByteString -> LinkIndex -> LinkIndex
updatePage page body ix =
    let cleared = clearSource page ix
        targets = pageTargets page body
        outbound' = Map.insert page targets (idxOutbound cleared)
        inbound' = foldl' (\m t -> addInbound t page m) (idxInbound cleared) targets
     in LinkIndex outbound' inbound'

{- | Removes a page as a link /source/: its outbound edges are withdrawn from the
inverse and its 'outbound' entry dropped. Other pages' edges /to/ this page are left
untouched (they reflect those pages' unchanged bodies, exactly as a rebuild would);
when a delete also rewrites a referrer, that referrer is re-derived separately.
-}
removePage :: PagePath -> LinkIndex -> LinkIndex
removePage = clearSource

{- | Re-keys a moved page: drops its old path's edges and records its new path's edges
from the (possibly rewritten) new body. Other pages whose links were rewritten to the
new path are maintained separately by re-deriving each (the move's write-set), so this
handles only the moved page's own key.
-}
relocatePage :: PagePath -> PagePath -> ByteString -> LinkIndex -> LinkIndex
relocatePage oldPath newPath newBody = updatePage newPath newBody . removePage oldPath

{- | The pages that link to a target the predicate accepts, excluding the given paths.
Mirrors 'MicroHttp.DocumentLinks.referrersMatching' as a page set: equality with a
target answers a page delete's refuse-if-referenced; a subtree-prefix predicate answers
a section delete's "who links into this subtree".
-}
referrers :: (TreePath -> Bool) -> [PagePath] -> LinkIndex -> [PagePath]
referrers matches excluded ix =
    nub [page | page <- linkersInto matches ix, page `notElem` excluded]

{- | The pages a move must consider rewriting: the moved subtree's own pages plus every
page linking into the subtree (ADR-066). A superset of the pages
'MicroHttp.DocumentLinks.planMoveRewrites' actually changes, so restricting the plan to
these candidates drops no rewrite while avoiding a whole-tree read.
-}
rewriteCandidates :: (TreePath -> Bool) -> LinkIndex -> [PagePath]
rewriteCandidates inSubtree ix =
    nub (subtreePages ++ linkersInto inSubtree ix)
  where
    subtreePages = [page | page <- Map.keys (idxOutbound ix), inSubtree page]

-- | The pages with an outbound edge to some target the predicate accepts (the inbound scan shared by the two queries).
linkersInto :: (TreePath -> Bool) -> LinkIndex -> [PagePath]
linkersInto matches ix =
    [ page
    | (target, pages) <- Map.toList (idxInbound ix)
    , matches target
    , page <- pages
    ]

-- | Withdraws a page's current outbound edges from the inverse and drops its outbound entry.
clearSource :: PagePath -> LinkIndex -> LinkIndex
clearSource page ix =
    let old = Map.findWithDefault [] page (idxOutbound ix)
        inbound' = foldl' (\m t -> removeInbound t page m) (idxInbound ix) old
     in LinkIndex (Map.delete page (idxOutbound ix)) inbound'

-- | Adds a page to a target's inbound list (kept sorted and unique).
addInbound :: TreePath -> PagePath -> Map TreePath [PagePath] -> Map TreePath [PagePath]
addInbound target page m =
    Map.insert target (insertSorted page (Map.findWithDefault [] target m)) m

-- | Removes a page from a target's inbound list, dropping the key when it empties.
removeInbound :: TreePath -> PagePath -> Map TreePath [PagePath] -> Map TreePath [PagePath]
removeInbound target page m =
    case filter (/= page) (Map.findWithDefault [] target m) of
        [] -> Map.delete target m
        remaining -> Map.insert target remaining m

-- | Inserts an element into an already-sorted list in one pass, ignoring a duplicate.
insertSorted :: (Ord a) => a -> [a] -> [a]
insertSorted x [] = [x]
insertSorted x rest@(y : ys)
    | x == y = rest
    | x < y = x : rest
    | otherwise = y : insertSorted x ys
