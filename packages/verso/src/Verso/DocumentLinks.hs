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
    ScanState,
    Scanned (..),
    initialScan,
    scanStep,
    scanChunk,
    scanFinish,
    scanFinishAll,
    scanChunks,
    carriedBytes,
    tailCapBytes,
    linksI,
    Edit,
    editsWith,
    moveLinkEdit,
    pageMoveLinkEdit,
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

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Unsafe as BSU
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Ptr as Ptr
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Utf8 as Utf8

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

The single-chunk case of the streaming scan: 'scanChunks' over the whole body, so
a body scanned in pieces yields exactly these links. In 'IO' because the scan is a
foreign call (ADR-0087).
-}
pageLinks :: BS.ByteString -> IO [Link]
pageLinks text = scanChunks [text]

{- | The state carried between chunks of a streaming scan (RFC-0039): whether
the scan is inside a fenced code block, the incomplete final line of the bytes
seen so far (the carry), and the byte offset of the carry's first byte in the
document, so link spans stay document-absolute across chunks.
-}
data ScanState = ScanState
    { scanInFence :: Bool
    , scanCarry :: BS.ByteString
    , scanBase :: Int
    }

-- | The state before any bytes: outside a fence, nothing carried, at offset 0.
initialScan :: ScanState
initialScan = ScanState False BS.empty 0

-- | The bytes a scan is carrying into the next chunk (bounded by 'tailCapBytes').
carriedBytes :: ScanState -> Int
carriedBytes = BS.length . scanCarry

{- | Scans one more chunk: the links in every complete line of the carry plus
the chunk, with the incomplete tail after the last newline carried forward (as a
private copy, so the chunk itself can be released). A tail longer than
'tailCapBytes' is scanned as a line at once -- a hard break -- so resident
memory is one chunk plus a bounded carry, never a whole document; a link or
fence marker split by such a break is not matched, which only a line longer
than the cap can cause.
-}
scanStep :: ScanState -> BS.ByteString -> IO (ScanState, [Link])
scanStep st chunk = fmap (\scanned -> (scannedState scanned, scannedLinks scanned)) (scanChunk st chunk)

{- | One step of a scan in full: the state to carry on with, and the bytes the step
settled (the complete lines, an O(1) view whose first byte sits at 'scannedBase' in
the document) with the links found in them. A rewriter splices those links into
those bytes; a scan that only wants links uses 'scanStep'.
-}
data Scanned = Scanned
    { scannedState :: ScanState
    , scannedBase :: Int
    , scannedSettled :: BS.ByteString
    , scannedLinks :: [Link]
    }

-- | 'scanStep' returning the settled bytes as well.
scanChunk :: ScanState -> BS.ByteString -> IO Scanned
scanChunk st chunk = do
    let buffer = if BS.null (scanCarry st) then chunk else BS.append (scanCarry st) chunk
    (inFence, tailStart, links) <- scanLines (scanInFence st) (scanBase st) False buffer
    let carry = if tailStart >= BS.length buffer then BS.empty else BS.copy (BS.drop tailStart buffer)
    pure (Scanned (ScanState inFence carry (scanBase st + tailStart)) (scanBase st) (BS.take tailStart buffer) links)

-- | Ends a scan: the links in the carried final line (a body need not end in a newline).
scanFinish :: ScanState -> IO [Link]
scanFinish = fmap scannedLinks . scanFinishAll

-- | 'scanFinish' returning the carried bytes it settled as well; the state is left empty.
scanFinishAll :: ScanState -> IO Scanned
scanFinishAll st
    | BS.null carry = pure (Scanned st (scanBase st) BS.empty [])
    | otherwise = do
        (inFence, _, links) <- scanLines (scanInFence st) (scanBase st) True carry
        pure (Scanned (ScanState inFence BS.empty (scanBase st + BS.length carry)) (scanBase st) carry links)
  where
    carry = scanCarry st

-- | The links of a body presented as chunks: 'scanStep' over each, then 'scanFinish'.
scanChunks :: [BS.ByteString] -> IO [Link]
scanChunks chunks = do
    (final, linksPerChunk) <- Monad.foldM step (initialScan, []) chunks
    finalLinks <- scanFinish final
    pure (concat (reverse linksPerChunk) ++ finalLinks)
  where
    step (st, acc) chunk = do
        (st', links) <- scanStep st chunk
        pure (st', links : acc)

{- | The links of a body arriving as a stream: 'scanStep' per chunk, 'scanFinish' at
end of stream. Holds the links found so far (O(links)) and the bounded carry, never
the body, so a producer such as 'MicroHttp.Stream.fileEnumeratorChunked' scans a
document in constant space.
-}
linksI :: Iteratee.Iter e [Link]
linksI = go initialScan []
  where
    go st acc = Iteratee.NeedInput (step st acc)
    step st acc stream = case stream of
        Iteratee.Chunk bytes
            | BS.null bytes -> go st acc
            | otherwise -> Iteratee.IterM $ do
                (st', links) <- scanStep st bytes
                pure (go st' (reverse links ++ acc))
        Iteratee.EndOfStream Nothing -> Iteratee.IterM $ do
            links <- scanFinish st
            pure (Iteratee.Done (reverse acc ++ links) stream)
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err stream

-- | The longest incomplete line 'scanStep' carries before scanning it as a hard break.
tailCapBytes :: Int
tailCapBytes = 65536

{- | The scanner core: the links in a buffer's complete lines from a fence state,
returning the fence state after them, the offset of the incomplete tail (the buffer
length when there is none, or when @final@ or the tail cap made it a line too), and
the links with @base@ added to their spans.

The scan is driven by libc @memchr@ over one marshalled copy of the buffer:
newline hits delimit lines (for the fence state), @]@ hits find the @](@
candidates, and a bounded @)@ search closes each target -- so the interpreter
touches only those positions, never every byte. On mhs this is ~5.6x fewer
cells (85MB -> 15MB per 73KB page) and ~4.5x faster than the previous per-byte
'BS.index' walk (@make bench-link-parse@); no pure-Haskell arrangement came
close, because any full scan pays ~50-100 interpreted cells per byte.

In 'IO' because a foreign call is one (ADR-0087); @memchr@ only reads, so the
buffer is passed in place without a copy.
-}
scanLines :: Bool -> Int -> Bool -> BS.ByteString -> IO (Bool, Int, [Link])
scanLines inFence0 base final text =
    BSU.unsafeUseAsCStringLen text $ \(basePtr, len) -> do
        let
            -- The first `wanted` byte at or after `i` but before `bound`, via memchr.
            findFrom i bound wanted
                | i >= bound = pure Nothing
                | otherwise = do
                    p <- c_memchr (Ptr.plusPtr basePtr i) (fromIntegral (Char.ord wanted)) (fromIntegral (bound - i))
                    pure (if p == Ptr.nullPtr then Nothing else Just (Ptr.minusPtr p basePtr))

            -- One line per iteration, links accumulated in reverse; stops at an incomplete tail
            -- unless the scan is final or the tail is past the cap.
            scanFrom inFence lineStart acc = do
                newline <- findFrom lineStart len '\n'
                case newline of
                    Just lineEnd -> do
                        (inFence', acc') <- scanLine inFence lineStart lineEnd acc
                        scanFrom inFence' (lineEnd + 1) acc'
                    Nothing
                        | lineStart >= len -> pure (inFence, len, reverse acc)
                        | final || len - lineStart > tailCapBytes -> do
                            (inFence', acc') <- scanLine inFence lineStart len acc
                            pure (inFence', len, reverse acc')
                        | otherwise -> pure (inFence, lineStart, reverse acc)

            -- Fence lines toggle, in-fence lines skip, others are scanned for links.
            scanLine inFence lineStart lineEnd acc
                | fenceLineAt lineStart lineEnd = pure (not inFence, acc)
                | inFence = pure (inFence, acc)
                | otherwise = do
                    links <- lineLinksAt lineStart lineEnd
                    pure (inFence, reverse links ++ acc)

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
                                            token = Utf8.decodeBytes (stripAngles raw)
                                            link = Link (base + j + 2) (base + j + 2 + BS.length raw) token
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

        if len == 0 then pure (inFence0, 0, []) else scanFrom inFence0 0 []

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
rewriteLinks :: BS.ByteString -> [Edit] -> BS.ByteString
rewriteLinks text edits = BS.concat (go 0 (List.sortBy byStart edits))
  where
    byStart (a, _, _) (b, _, _) = compare a b
    go cursor [] = [BS.drop cursor text]
    go cursor ((start, end, replacement) : rest)
        | start < cursor = go cursor rest -- overlapping/out-of-order: skip
        | otherwise = sliceBetween cursor start : Utf8.encodeText replacement : go end rest
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

-- | A span replacement: the half-open byte span @[start, end)@ and the bytes to put there.
type Edit = (Int, Int, String)

-- | The edits a per-link decision yields over a page's links: the span of each link it replaces.
editsWith :: (Link -> Maybe String) -> [Link] -> [Edit]
editsWith decide links = [(linkStart l, linkEnd l, replacement) | l <- links, Just replacement <- [decide l]]

{- | The decision for one link of the page at @path@ under the subtree relocation
@(oldPrefix, newPrefix)@: the new target token when the current token would no longer
resolve to the target's new location from the page's new directory, else 'Nothing'.
A pure move thus leaves intra-subtree and unrelated links byte-for-byte unchanged; a
move that also renames additionally fixes internal links routing through the old name.
-}
moveLinkEdit :: (String, String) -> String -> Link -> Maybe String
moveLinkEdit (oldPrefix, newPrefix) path l =
    case resolveTarget oldDir (linkTarget l) of
        Nothing -> Nothing
        Just oldTarget ->
            let newTarget = Maybe.fromMaybe oldTarget (reloc oldTarget)
             in if resolveTarget newDir pathPart /= Just newTarget
                    then Just (relativeBetween newDir newTarget ++ suffix)
                    else Nothing
  where
    reloc = relocatePath oldPrefix newPrefix
    oldDir = dirOfPath path
    newDir = Maybe.fromMaybe oldDir (reloc oldDir)
    (pathPart, suffix) = splitTargetSuffix (linkTarget l)

{- | Plans the link rewrites a move induces across the tree. Given the relocation
@(oldPrefix, newPrefix)@ and every page as @(treePath, links)@ (paths at their
*current* locations), it returns the edits for each page whose body changes, per
'moveLinkEdit'.

The two parent index.md listings are reconciled separately (their membership entry
relocates, not repoints) and so are excluded by the caller from the page set here.
-}
planMoveRewrites :: (String, String) -> [(String, [Link])] -> [(String, [Edit])]
planMoveRewrites relocation pages =
    [ (path, edits)
    | (path, links) <- pages
    , let edits = editsWith (moveLinkEdit relocation path) links
    , not (null edits)
    ]

{- | The decision for one link of the moved page itself under a page move from
@oldPath@ to @newPath@. A page move changes the page's own directory, so its outward
@.md@ links are re-pointed, a self-link re-pointed, and its @assets/@ refs left as the
same relative token (the assets travel into the destination's @assets/@).
-}
pageMoveLinkEdit :: (String, String) -> Link -> Maybe String
pageMoveLinkEdit (oldPath, newPath) l =
    case resolveTarget oldDir pathPart of
        Nothing -> Nothing
        Just oldTarget ->
            let newTarget = relocateMovedTarget oldTarget
             in if resolveTarget newDir pathPart /= Just newTarget
                    then Just (relativeBetween newDir newTarget ++ suffix)
                    else Nothing
  where
    oldDir = dirOfPath oldPath
    newDir = dirOfPath newPath
    (pathPart, suffix) = splitTargetSuffix (linkTarget l)
    relocateMovedTarget t =
        Maybe.fromMaybe t (orElse (relocatePath oldPath newPath t) (relocatePath (assetsDir oldDir) (assetsDir newDir) t))
    orElse (Just x) _ = Just x
    orElse Nothing y = y

{- | Plans the link rewrites a single page move induces: the moved page's own edits
('pageMoveLinkEdit', keyed by its new path) and every other page's inbound fixes
('moveLinkEdit', the file itself being the relocated prefix).
-}
planPageMove :: (String, String) -> [(String, [Link])] -> [(String, [Edit])]
planPageMove (oldPath, newPath) pages =
    movedEntry ++ planMoveRewrites (oldPath, newPath) others
  where
    others = filter ((/= oldPath) . fst) pages
    movedEntry =
        [ (newPath, edits)
        | Just links <- [lookup oldPath pages]
        , let edits = editsWith (pageMoveLinkEdit (oldPath, newPath)) links
        , not (null edits)
        ]

-- | The page-relative @assets@ directory tree path for a page directory (@assets@ at the root).
assetsDir :: String -> String
assetsDir "" = "assets"
assetsDir dir = dir ++ "/assets"

{- | The asset basenames a page's links reference (the names after a same-page
@assets/@ prefix in inline link/image targets), in order, for the shared/exclusive
analysis of a cross-folder page move (ADR-0062).
-}
assetNamesIn :: [Link] -> [String]
assetNamesIn links =
    [ name
    | l <- links
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
referrersMatching :: (String -> Bool) -> [String] -> [(String, [Link])] -> [(String, String)]
referrersMatching matches excluded pages =
    [ (path, linkTarget l)
    | (path, links) <- pages
    , path `notElem` excluded
    , l <- links
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
