{- | The pure link engine for in-server move and delete (RFC-0027). It works over a
page's Markdown body as a strict 'ByteString' (so offsets are byte offsets, ASCII link
syntax is matched exactly regardless of UTF-8 content, and the whole-tree scan/index
build never pays a @String@ conversion of every body -- RFC-0029) and over tree-relative
paths as 'String' (link tokens and paths are short).

The functions are pure and independently testable: 'pageLinks' extracts the inline
link and image targets (with their spans), 'resolveTarget' resolves a relative
target against the linking page's directory to a tree-absolute path,
'relativeBetween' is the inverse (the relative target to write to reach a tree
path), and 'rewriteLinks' applies span replacements byte-for-byte elsewhere.
Reference-style and raw-HTML links are not matched (the corpus has none in-tree);
fenced code blocks are skipped.
-}
module MicroHttp.DocumentLinks (
    Link (..),
    pageLinks,
    splitTargetSuffix,
    isExternalTarget,
    resolveTarget,
    relativeBetween,
    rewriteLinks,
    pathSegmentsOf,
    relocatePath,
    planMoveRewrites,
    planPageMove,
    assetNamesIn,
    AssetClass (..),
    classifyAssets,
    referrersMatching,
    dirOfPath,
) where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.List (intercalate, isPrefixOf, sortBy)
import Data.Maybe (fromMaybe)

{- | An inline link or image target in a page body: the raw target token (the text
between @](@ and the closing @)@ or a title, which may carry a @#anchor@/@?query@
suffix) and its half-open char span @[start, end)@ in the page text, for in-place
rewriting.
-}
data Link = Link
    { linkStart :: Int
    , linkEnd :: Int
    , linkTarget :: String
    }
    deriving (Eq, Show)

{- | The inline link and image targets in a page body, in order. Matches
@](target)@ (so both @[text](target)@ and @![alt](target)@), skipping fenced code
blocks (``` and @~~~@). A title (@](path "title")@) is excluded from the target;
the target token is the path plus any @#anchor@/@?query@.
-}
pageLinks :: ByteString -> [Link]
pageLinks text = concat (scanLines False (linesWithOffsets text))
  where
    scanLines _ [] = []
    scanLines inFence ((lineOff, line) : rest)
        | isFenceLine line = [] : scanLines (not inFence) rest
        | inFence = [] : scanLines inFence rest
        | otherwise = lineLinks lineOff line : scanLines inFence rest

{- | The links on one (non-fence) line, with absolute spans from the line's offset.
Walks the line once with O(1) 'ByteString' indexing (@BS.index@/@BS.drop@), so no
@length@/@drop@ rescan and no @String@ allocation.
-}
lineLinks :: Int -> ByteString -> [Link]
lineLinks lineOff line = go 0
  where
    len = BS.length line
    go i
        | i + 1 >= len = []
        | BS.index line i == ']' && BS.index line (i + 1) == '(' =
            case readTarget (BS.drop (i + 2) line) of
                Just (token, tokenLen) ->
                    Link (lineOff + i + 2) (lineOff + i + 2 + tokenLen) token : go (i + 2 + tokenLen)
                Nothing -> go (i + 1)
        | otherwise = go (i + 1)

{- | From the bytes just after @](@, the target token and its length in the source
(the raw path span, excluding any leading @<@/@>@, a following title, or the closing
@)@). 'Nothing' if no closing @)@ is found on the line. The token is returned as a
'String' (it is short).
-}
readTarget :: ByteString -> Maybe (String, Int)
readTarget afterOpen = case BS.elemIndex ')' afterOpen of
    Nothing -> Nothing
    Just _ -> Just (BS.unpack (stripAngles raw), BS.length raw)
  where
    inner = BS.takeWhile (/= ')') afterOpen
    raw = BS.takeWhile (\c -> c /= ' ' && c /= '\t') inner
    stripAngles t
        | BS.length t >= 2 && BS.head t == '<' && BS.last t == '>' = BS.init (BS.drop 1 t)
        | otherwise = t

{- | Splits a target token into its path part and a trailing @#anchor@/@?query@
suffix (empty when there is none), so a path can be rewritten while the suffix is
preserved verbatim.
-}
splitTargetSuffix :: String -> (String, String)
splitTargetSuffix = break (\c -> c == '#' || c == '?')

{- | Whether a target points outside the tree and so is never rewritten: a scheme
(@https:@, @mailto:@, ...), a protocol-relative @//@, an absolute @/path@, or an
empty path (a pure @#anchor@).
-}
isExternalTarget :: String -> Bool
isExternalTarget target =
    null path
        || "//" `isPrefixOf` path
        || (not (null path) && head path == '/')
        || hasScheme path
  where
    (path, _) = splitTargetSuffix target
    hasScheme s = case break (\c -> c == ':' || c == '/') s of
        (scheme, ':' : _) -> not (null scheme)
        _ -> False

{- | Resolves a relative target against the linking page's directory (tree-relative,
@""@ for the root) to a tree-absolute path, or 'Nothing' for an external target or
one that escapes the root. The @#anchor@/@?query@ suffix is dropped.
-}
resolveTarget :: String -> String -> Maybe String
resolveTarget dir target
    | isExternalTarget target = Nothing
    | otherwise = fmap (intercalate "/") (normaliseSegments (pathSegmentsOf dir ++ pathSegmentsOf path))
  where
    (path, _) = splitTargetSuffix target

{- | The relative target to write from a page in @fromDir@ (tree-relative) to reach
the tree path @toPath@. Same-directory or descendant targets are @./@-prefixed
(the corpus convention); ancestor/sibling targets use @../@ chains.
-}
relativeBetween :: String -> String -> String
relativeBetween fromDir toPath
    | ups == 0 = "./" ++ intercalate "/" (downs ++ [fileName])
    | otherwise = intercalate "/" (replicate ups ".." ++ downs ++ [fileName])
  where
    fromSegs = pathSegmentsOf fromDir
    toSegs = pathSegmentsOf toPath
    toDirSegs = if null toSegs then [] else init toSegs
    fileName = if null toSegs then "" else last toSegs
    common = commonPrefixLength fromSegs toDirSegs
    ups = length fromSegs - common
    downs = drop common toDirSegs

{- | Applies @(start, end, replacement)@ byte-span edits to the body, preserving everything else.

LATENT PERF (low priority): the final 'BS.concat' over the ~2N slice/replacement pieces is,
in mhs, @foldr append@ where @append@ memcpys into a fresh buffer, so it re-copies the
growing accumulator -> O(totalOutput * pieceCount) ~= O(len*N) for N edits. ('sliceBetween'
itself is fine -- @BS.take@/@BS.drop@ are O(1) buffer-views.) This only runs on the
move/delete rewrite path (rare; the rewrite set is small; measured ~39 ms warm), so it is
not a problem today. It would become O(len) with a single-allocation concat (sum the
lengths, allocate once, write each piece). See the mhs BS cost model in
docs/design/link-index-performance.md.
-}
rewriteLinks :: ByteString -> [(Int, Int, String)] -> ByteString
rewriteLinks text edits = BS.concat (go 0 (sortBy byStart edits))
  where
    byStart (a, _, _) (b, _, _) = compare a b
    go cursor [] = [BS.drop cursor text]
    go cursor ((start, end, replacement) : rest)
        | start < cursor = go cursor rest -- overlapping/out-of-order: skip
        | otherwise = sliceBetween cursor start : BS.pack replacement : go end rest
    sliceBetween from to = BS.take (to - from) (BS.drop from text)

{- | Relocates a tree path that lies within a moved subtree: the subtree root
@oldPrefix@ itself, or any descendant under it, maps to the same suffix beneath
@newPrefix@. 'Nothing' for a path outside the subtree (left where it is). The
prefixes are non-empty tree paths (the root never moves), and a sibling whose name
merely starts with @oldPrefix@ (e.g. @a/bc@ vs @a/b@) is not matched.
-}
relocatePath :: String -> String -> String -> Maybe String
relocatePath oldPrefix newPrefix p
    | p == oldPrefix = Just newPrefix
    | (oldPrefix ++ "/") `isPrefixOf` p = Just (newPrefix ++ drop (length oldPrefix) p)
    | otherwise = Nothing

{- | Plans the link rewrites a move induces across the tree. Given the relocation
@(oldPrefix, newPrefix)@ and every page as @(treePath, body)@ (paths at their
*current* locations), it returns @(treePath, newBody)@ for each page whose body
changes. A link is rewritten only when its current token would no longer resolve to
the target's new location from the page's new directory, so a pure move leaves
intra-subtree links and unrelated links byte-for-byte unchanged; a move that also
renames additionally fixes internal links routing through the old name.

The two parent index.md listings are reconciled separately (their membership entry
relocates, not repoints) and so are excluded by the caller from the page set here.
-}
planMoveRewrites :: (String, String) -> [(String, ByteString)] -> [(String, ByteString)]
planMoveRewrites (oldPrefix, newPrefix) pages =
    [ (path, rewriteLinks text edits)
    | (path, text) <- pages
    , let edits = pageEdits path text
    , not (null edits)
    ]
  where
    reloc = relocatePath oldPrefix newPrefix
    pageEdits path text =
        let oldDir = dirOfPath path
            newDir = fromMaybe oldDir (reloc oldDir)
         in [ (linkStart l, linkEnd l, relativeBetween newDir newTarget ++ suffix)
            | l <- pageLinks text
            , let (pathPart, suffix) = splitTargetSuffix (linkTarget l)
            , Just oldTarget <- [resolveTarget oldDir (linkTarget l)]
            , let newTarget = fromMaybe oldTarget (reloc oldTarget)
            , resolveTarget newDir pathPart /= Just newTarget
            ]

{- | Plans the link rewrites a single page move induces. Unlike 'planMoveRewrites'
(which relocates a whole subtree prefix), a page move changes the moved page's own
directory, so the moved page is rewritten against its new directory -- its outward
@.md@ links re-pointed, a self-link re-pointed, and its @assets/@ refs left as the
same relative token (the assets travel into the destination's @assets/@) -- while
every other page's inbound links to it are fixed by the subtree machinery (the file
itself is the relocated prefix). The moved page's result is keyed by its new path.
-}
planPageMove :: (String, String) -> [(String, ByteString)] -> [(String, ByteString)]
planPageMove (oldPath, newPath) pages =
    movedEntry ++ planMoveRewrites (oldPath, newPath) others
  where
    others = filter ((/= oldPath) . fst) pages
    oldDir = dirOfPath oldPath
    newDir = dirOfPath newPath
    oldAssets = assetsDir oldDir
    newAssets = assetsDir newDir
    movedEntry = case lookup oldPath pages of
        Nothing -> []
        Just body ->
            let edits =
                    [ (linkStart l, linkEnd l, relativeBetween newDir newTarget ++ suffix)
                    | l <- pageLinks body
                    , let (pathPart, suffix) = splitTargetSuffix (linkTarget l)
                    , Just oldTarget <- [resolveTarget oldDir pathPart]
                    , let newTarget = relocateMovedTarget oldTarget
                    , resolveTarget newDir pathPart /= Just newTarget
                    ]
                rewritten = rewriteLinks body edits
             in [(newPath, rewritten) | rewritten /= body]
    relocateMovedTarget t =
        fromMaybe t (orElse (relocatePath oldPath newPath t) (relocatePath oldAssets newAssets t))
    orElse (Just x) _ = Just x
    orElse Nothing y = y

-- | The page-relative @assets@ directory tree path for a page directory (@assets@ at the root).
assetsDir :: String -> String
assetsDir "" = "assets"
assetsDir dir = dir ++ "/assets"

{- | The asset basenames a page body references (the names after a same-page
@assets/@ prefix in inline link/image targets), in order, for the shared/exclusive
analysis of a cross-folder page move (ADR-062).
-}
assetNamesIn :: ByteString -> [String]
assetNamesIn body =
    [ name
    | l <- pageLinks body
    , let (pathPart, _) = splitTargetSuffix (linkTarget l)
    , Just name <- [assetBasename pathPart]
    ]
  where
    assetBasename p = case dropWhile (== ".") (pathSegmentsOf p) of
        ("assets" : rest@(_ : _)) -> Just (intercalate "/" rest)
        _ -> Nothing

-- | Whether a peer asset is referenced only by the moving page ('ExclusiveAsset') or by a sibling too ('SharedAsset').
data AssetClass = ExclusiveAsset | SharedAsset
    deriving (Eq, Show)

{- | Classifies each of the moving page's asset names against the peer pages' asset
references (each peer's referenced names): 'SharedAsset' when any peer references it,
'ExclusiveAsset' otherwise (ADR-062). Exclusive assets relocate, shared ones copy.
-}
classifyAssets :: [String] -> [[String]] -> [(String, AssetClass)]
classifyAssets moving peerRefs =
    [(asset, if any (asset `elem`) peerRefs then SharedAsset else ExclusiveAsset) | asset <- moving]

{- | The inbound references to a delete target: each page (excluding @excluded@
paths) and the raw link token of every one of its links that resolves to a path the
@matches@ predicate accepts. For a page delete @matches@ is equality with the target;
for a section delete it accepts the subtree (the folder and its descendants), and the
subtree's own pages are excluded. Used to refuse a referenced delete (RFC-0027,
ADR-063) and list the referrers.
-}
referrersMatching :: (String -> Bool) -> [String] -> [(String, ByteString)] -> [(String, String)]
referrersMatching matches excluded pages =
    [ (path, linkTarget l)
    | (path, body) <- pages
    , path `notElem` excluded
    , l <- pageLinks body
    , Just target <- [resolveTarget (dirOfPath path) (linkTarget l)]
    , matches target
    ]

-- | The tree-relative directory holding a page (its path minus the final segment; @""@ at the root).
dirOfPath :: String -> String
dirOfPath p = intercalate "/" (initOrEmpty (pathSegmentsOf p))
  where
    initOrEmpty [] = []
    initOrEmpty xs = init xs

-- | The non-empty @/@-separated segments of a path.
pathSegmentsOf :: String -> [String]
pathSegmentsOf = filter (not . null) . splitOnSlash
  where
    splitOnSlash s = case break (== '/') s of
        (seg, '/' : rest) -> seg : splitOnSlash rest
        (seg, _) -> [seg]

{- | Normalises @.@/@..@ in a segment list to an absolute segment list, or 'Nothing'
if a @..@ escapes the root.
-}
normaliseSegments :: [String] -> Maybe [String]
normaliseSegments = go []
  where
    go acc [] = Just (reverse acc)
    go acc ("." : rest) = go acc rest
    go [] (".." : _) = Nothing
    go (_ : accRest) (".." : rest) = go accRest rest
    go acc (seg : rest) = go (seg : acc) rest

-- | The length of the common prefix of two segment lists.
commonPrefixLength :: [String] -> [String] -> Int
commonPrefixLength (a : as) (b : bs)
    | a == b = 1 + commonPrefixLength as bs
commonPrefixLength _ _ = 0

{- | The page's lines as @(startOffset, lineBytes)@ pairs, split on @\\n@ (the line
bytes exclude the newline; a trailing @\\r@ stays so offsets are exact). Each line's
offset is the running sum of the preceding lines' lengths plus their newline byte.

Splits with a single 'BS.split' pass rather than recursing with @BS.elemIndex@: in mhs
@BS.elemIndex@ is @elemIndex . unpack@, so it unpacks the __whole remaining ByteString__
to a list on every call; recursing it down the tail therefore re-unpacks O(n) bytes per
line -> O(n^2) overall, which dominated the whole-tree index build (~23 s of a ~27 s parse
on the reference corpus). ('BS.drop'/'BS.take' here are O(1) buffer-views, not the cost.)
'BS.split' unpacks once and splits the list in a single linear pass (~2 s), making the
parser ~5.8x faster with byte-identical output. (mhs BS cost model: see
docs/design/link-index-performance.md.)
-}
linesWithOffsets :: ByteString -> [(Int, ByteString)]
linesWithOffsets text = withOffsets 0 (BS.split '\n' text)
  where
    withOffsets _ [] = []
    withOffsets off (line : rest) = (off, line) : withOffsets (off + BS.length line + 1) rest

-- | Whether a line opens or closes a fenced code block (``` or @~~~@ after optional indent).
isFenceLine :: ByteString -> Bool
isFenceLine line =
    let trimmed = BS.dropWhile (== ' ') line
     in BS.pack "```" `BS.isPrefixOf` trimmed || BS.pack "~~~" `BS.isPrefixOf` trimmed
