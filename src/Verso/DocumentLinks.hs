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
module Verso.DocumentLinks (
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

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Ptr as Ptr
import qualified System.IO.Unsafe as Unsafe

foreign import ccall "string.h memchr" c_memchr :: CStr.CString -> CTypes.CInt -> CTypes.CSize -> IO (Ptr.Ptr ())

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

The scan is driven by libc @memchr@ over one marshalled copy of the body:
newline hits delimit lines (for the fence state), @]@ hits find the @](@
candidates, and a bounded @)@ search closes each target -- so the interpreter
touches only those positions, never every byte. On mhs this is ~5.6x fewer
cells (85MB -> 15MB per 73KB page) and ~4.5x faster than the previous per-byte
'BS.index' walk (@make bench-link-parse@); no pure-Haskell arrangement came
close, because any full scan pays ~50-100 interpreted cells per byte. Pure
despite the FFI: @memchr@ only reads the copied bytes, so the result depends
on the argument alone.
-}
pageLinks :: BS.ByteString -> [Link]
pageLinks text = Unsafe.unsafePerformIO $
    BS.useAsCStringLen text $ \(basePtr, len) -> do
        let
            -- The first `wanted` byte at or after `i` but before `bound`, via memchr.
            findFrom i bound wanted
                | i >= bound = pure Nothing
                | otherwise = do
                    p <- c_memchr (Ptr.plusPtr basePtr i) (fromIntegral (Char.ord wanted)) (fromIntegral (bound - i))
                    pure (if p == Ptr.nullPtr then Nothing else Just (Ptr.minusPtr p basePtr))

            -- One line per iteration: fence lines toggle, in-fence lines skip, others scan.
            scanLines inFence lineStart = do
                lineEnd <- Maybe.fromMaybe len <$> findFrom lineStart len '\n'
                let continue fence rest = if lineEnd >= len then pure rest else fmap (rest ++) (scanLines fence (lineEnd + 1))
                if fenceLineAt lineStart lineEnd
                    then continue (not inFence) []
                    else
                        if inFence
                            then continue inFence []
                            else lineLinksAt lineStart lineEnd >>= continue inFence

            -- The links between two candidate-scan positions on one (non-fence) line.
            lineLinksAt i lineEnd
                | i + 1 >= lineEnd = pure []
                | otherwise = do
                    candidate <- findFrom i lineEnd ']'
                    case candidate of
                        Nothing -> pure []
                        Just j
                            | j + 1 >= lineEnd || BS.index text (j + 1) /= '(' -> lineLinksAt (j + 1) lineEnd
                            | otherwise -> do
                                closing <- findFrom (j + 2) lineEnd ')'
                                case closing of
                                    -- No @)@ later on this line: no further candidate can close either.
                                    Nothing -> pure []
                                    Just close ->
                                        let inner = BS.take (close - j - 2) (BS.drop (j + 2) text)
                                            raw = BS.takeWhile (\c -> c /= ' ' && c /= '\t') inner
                                            token = BS.unpack (stripAngles raw)
                                            link = Link (j + 2) (j + 2 + BS.length raw) token
                                         in (link :) <$> lineLinksAt (j + 2 + BS.length raw) lineEnd

            -- Fence marker (``` or ~~~) after optional indent, checked byte-wise (O(indent), not O(line)).
            fenceLineAt lineStart lineEnd = go lineStart
              where
                go k
                    | k < lineEnd && BS.index text k == ' ' = go (k + 1)
                    | otherwise = k + 2 < lineEnd && (tripleAt k '`' || tripleAt k '~')
                tripleAt k c = BS.index text k == c && BS.index text (k + 1) == c && BS.index text (k + 2) == c

            stripAngles t
                | BS.length t >= 2 && BS.head t == '<' && BS.last t == '>' = BS.init (BS.drop 1 t)
                | otherwise = t

        if len == 0 then pure [] else scanLines False 0

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
        || "//" `List.isPrefixOf` path
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
    | otherwise = fmap (List.intercalate "/") (normaliseSegments (pathSegmentsOf dir ++ pathSegmentsOf path))
  where
    (path, _) = splitTargetSuffix target

{- | The relative target to write from a page in @fromDir@ (tree-relative) to reach
the tree path @toPath@. Same-directory or descendant targets are @./@-prefixed
(the corpus convention); ancestor/sibling targets use @../@ chains.
-}
relativeBetween :: String -> String -> String
relativeBetween fromDir toPath
    | ups == 0 = "./" ++ List.intercalate "/" (downs ++ [fileName])
    | otherwise = List.intercalate "/" (replicate ups ".." ++ downs ++ [fileName])
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
rewriteLinks :: BS.ByteString -> [(Int, Int, String)] -> BS.ByteString
rewriteLinks text edits = BS.concat (go 0 (List.sortBy byStart edits))
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
    | (oldPrefix ++ "/") `List.isPrefixOf` p = Just (newPrefix ++ drop (length oldPrefix) p)
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
planMoveRewrites :: (String, String) -> [(String, BS.ByteString)] -> [(String, BS.ByteString)]
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
            newDir = Maybe.fromMaybe oldDir (reloc oldDir)
         in [ (linkStart l, linkEnd l, relativeBetween newDir newTarget ++ suffix)
            | l <- pageLinks text
            , let (pathPart, suffix) = splitTargetSuffix (linkTarget l)
            , Just oldTarget <- [resolveTarget oldDir (linkTarget l)]
            , let newTarget = Maybe.fromMaybe oldTarget (reloc oldTarget)
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
planPageMove :: (String, String) -> [(String, BS.ByteString)] -> [(String, BS.ByteString)]
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
        Maybe.fromMaybe t (orElse (relocatePath oldPath newPath t) (relocatePath oldAssets newAssets t))
    orElse (Just x) _ = Just x
    orElse Nothing y = y

-- | The page-relative @assets@ directory tree path for a page directory (@assets@ at the root).
assetsDir :: String -> String
assetsDir "" = "assets"
assetsDir dir = dir ++ "/assets"

{- | The asset basenames a page body references (the names after a same-page
@assets/@ prefix in inline link/image targets), in order, for the shared/exclusive
analysis of a cross-folder page move (ADR-0062).
-}
assetNamesIn :: BS.ByteString -> [String]
assetNamesIn body =
    [ name
    | l <- pageLinks body
    , let (pathPart, _) = splitTargetSuffix (linkTarget l)
    , Just name <- [assetBasename pathPart]
    ]
  where
    assetBasename p = case dropWhile (== ".") (pathSegmentsOf p) of
        ("assets" : rest@(_ : _)) -> Just (List.intercalate "/" rest)
        _ -> Nothing

-- | Whether a peer asset is referenced only by the moving page ('ExclusiveAsset') or by a sibling too ('SharedAsset').
data AssetClass = ExclusiveAsset | SharedAsset
    deriving (Eq, Show)

{- | Classifies each of the moving page's asset names against the peer pages' asset
references (each peer's referenced names): 'SharedAsset' when any peer references it,
'ExclusiveAsset' otherwise (ADR-0062). Exclusive assets relocate, shared ones copy.
-}
classifyAssets :: [String] -> [[String]] -> [(String, AssetClass)]
classifyAssets moving peerRefs =
    [(asset, if any (asset `elem`) peerRefs then SharedAsset else ExclusiveAsset) | asset <- moving]

{- | The inbound references to a delete target: each page (excluding @excluded@
paths) and the raw link token of every one of its links that resolves to a path the
@matches@ predicate accepts. For a page delete @matches@ is equality with the target;
for a section delete it accepts the subtree (the folder and its descendants), and the
subtree's own pages are excluded. Used to refuse a referenced delete (RFC-0027,
ADR-0063) and list the referrers.
-}
referrersMatching :: (String -> Bool) -> [String] -> [(String, BS.ByteString)] -> [(String, String)]
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
dirOfPath p = List.intercalate "/" (initOrEmpty (pathSegmentsOf p))
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
