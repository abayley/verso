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
) where

import Data.List (intercalate, isPrefixOf, sortBy)

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
