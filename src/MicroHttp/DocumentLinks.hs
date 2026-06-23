{- | The pure link engine for in-server move and delete (RFC-0027). It works over a
page's Markdown text as a plain 'String' (the @ByteString.Char8.unpack@ form, one
'Char' per byte, so offsets are byte offsets and ASCII link syntax is matched
exactly regardless of UTF-8 content) and over tree-relative paths.

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
) where

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
pageLinks :: String -> [Link]
pageLinks text = concat (scanLines 0 False (linesWithOffsets text))
  where
    scanLines _ _ [] = []
    scanLines off inFence ((lineOff, line) : rest)
        | isFenceLine line = [] : scanLines (off + lineLen) (not inFence) rest
        | inFence = [] : scanLines (off + lineLen) inFence rest
        | otherwise = lineLinks lineOff line : scanLines (off + lineLen) inFence rest
      where
        lineLen = length line + 1

-- | The links on one (non-fence) line, with absolute spans from the line's offset.
lineLinks :: Int -> String -> [Link]
lineLinks lineOff line = go 0
  where
    go i
        | i + 1 >= length line = []
        | take 2 (drop i line) == "](" =
            case readTarget (drop (i + 2) line) of
                Just (token, tokenLen) ->
                    Link (lineOff + i + 2) (lineOff + i + 2 + tokenLen) token : go (i + 2 + tokenLen)
                Nothing -> go (i + 1)
        | otherwise = go (i + 1)

{- | From the text just after @](@, the target token and its length in the source
(the raw path span, excluding any leading @<@/@>@, a following title, or the closing
@)@). 'Nothing' if no closing @)@ is found on the line.
-}
readTarget :: String -> Maybe (String, Int)
readTarget afterOpen =
    case break (== ')') afterOpen of
        (_, []) -> Nothing
        (inner, _) -> Just (tokenOf inner, length (rawTokenOf inner))
  where
    rawTokenOf = takeWhile (\c -> c /= ' ' && c /= '\t')
    tokenOf inner = stripAngles (rawTokenOf inner)
    stripAngles t
        | not (null t) && head t == '<' && not (null (drop 1 t)) && last t == '>' = init (drop 1 t)
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

-- | Applies @(start, end, replacement)@ span edits to the text, preserving everything else.
rewriteLinks :: String -> [(Int, Int, String)] -> String
rewriteLinks text edits = go 0 (sortBy byStart edits)
  where
    byStart (a, _, _) (b, _, _) = compare a b
    go cursor [] = drop cursor text
    go cursor ((start, end, replacement) : rest)
        | start < cursor = go cursor rest -- overlapping/out-of-order: skip
        | otherwise = sliceBetween cursor start ++ replacement ++ go end rest
    sliceBetween from to = take (to - from) (drop from text)

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
planMoveRewrites :: (String, String) -> [(String, String)] -> [(String, String)]
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
planPageMove :: (String, String) -> [(String, String)] -> [(String, String)]
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
assetNamesIn :: String -> [String]
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

{- | The page's lines as @(startOffset, lineText)@ pairs, split on @\\n@ (the line
text excludes the newline; a trailing @\\r@ stays in the text so offsets are exact).
-}
linesWithOffsets :: String -> [(Int, String)]
linesWithOffsets = go 0
  where
    go off s = case break (== '\n') s of
        (line, '\n' : rest) -> (off, line) : go (off + length line + 1) rest
        (line, _) -> [(off, line)]

-- | Whether a line opens or closes a fenced code block (``` or @~~~@ after optional indent).
isFenceLine :: String -> Bool
isFenceLine line =
    let trimmed = dropWhile (== ' ') line
     in "```" `isPrefixOf` trimmed || "~~~" `isPrefixOf` trimmed
