{- | Splits a page into search-index chunks (RFC-0034): one chunk per ATX
heading section (fence-aware, so a @#@ comment inside a code fence never
starts a section), each prefixed by a context line of the page title plus
ancestor heading path. Sections beyond the size cap split at paragraph
boundaries. Pure: the caller supplies the page title and raw content.
-}
module Verso.SearchChunks (
    Chunk (..),
    chunkPage,
) where

-- | One search-index chunk of a page.
data Chunk = Chunk
    { chunkAnchor :: String
    -- ^ The section's heading text; empty for the pre-heading preamble.
    , chunkSeq :: Int
    -- ^ The chunk's order within the page.
    , chunkText :: String
    -- ^ Context line plus section Markdown (frontmatter stripped).
    }
    deriving (Eq, Show)

{- | Chunks a page: context line (title plus ancestor headings), heading
sections, size-capped (in characters) at paragraph boundaries.
-}
chunkPage :: Int -> String -> String -> [Chunk]
chunkPage cap title content =
    [ Chunk anchor seqNo (context ++ "\n" ++ body)
    | (seqNo, (anchor, context, body)) <- zip [0 ..] (concatMap capPieces usable)
    ]
  where
    usable = [s | s@(_, _, body) <- sections title (stripFrontmatter content), not (null body)]
    capPieces (anchor, context, body) =
        case splitAtParagraphs cap body of
            [] -> []
            (first : rest) ->
                (anchor, context, first)
                    : [(anchor, continuationContext anchor context, piece) | piece <- rest]
    continuationContext anchor context =
        if null anchor then context else context ++ " > " ++ anchor

{- | Splits text into pieces of at most the cap (in characters) at blank-line
paragraph boundaries; a single paragraph beyond the cap stays whole. The
accumulator carries its running length (re-measuring it per paragraph was
quadratic) and joins once per piece.
-}
splitAtParagraphs :: Int -> String -> [String]
splitAtParagraphs cap body = go (paragraphs body)
  where
    go [] = []
    go (p : ps) = accumulate (length p) [p] ps
    accumulate len acc (p : ps)
        | len + 2 + length p <= cap = accumulate (len + 2 + length p) (p : acc) ps
    accumulate _ acc ps = joinParagraphs (reverse acc) : go ps
    joinParagraphs = concat . interleave "\n\n"

{- | Splits text into paragraphs at blank lines outside code fences. Lines
accumulate reversed (consing; @acc ++ [l]@ per line was quadratic) and each
paragraph is assembled once at emit.
-}
paragraphs :: String -> [String]
paragraphs body = go False [] (lines body)
  where
    go _ acc [] = emit acc
    go inFence acc (l : ls)
        | isFenceLine l = go (not inFence) (l : acc) ls
        | not inFence && null (trimBlank l) = emit acc ++ go False [] ls
        | otherwise = go inFence (l : acc) ls
    emit [] = []
    emit acc = [trimBlank (unlines (reverse acc))]

-- | Whether a line opens or closes a code fence.
isFenceLine :: String -> Bool
isFenceLine l = take 3 (dropWhile (== ' ') l) == "```"

{- | Splits the (frontmatter-free) body into heading sections, each carrying
its heading text (empty for the preamble) and its context line: title plus
the @ > @-joined ancestor heading path.
-}
sections :: String -> String -> [(String, String, String)]
sections title body = go False [] "" [] (lines body)
  where
    go _ ancestors anchor acc [] = [emit ancestors anchor acc]
    go inFence ancestors anchor acc (l : ls)
        | isFence l = go (not inFence) ancestors anchor (l : acc) ls
        | inFence = go inFence ancestors anchor (l : acc) ls
        | otherwise =
            case headingOf l of
                Just (level, text) ->
                    emit ancestors anchor acc
                        : go False (trimAncestors level ancestors ++ [(level, text)]) text [l] ls
                Nothing -> go False ancestors anchor (l : acc) ls
    isFence = isFenceLine
    -- Section lines accumulate reversed (consing; @acc ++ [l]@ per line was quadratic).
    emit ancestors anchor acc =
        (anchor, context (if null anchor then ancestors else init ancestors), trimBlank (unlines (reverse acc)))
    context ancestors = concat (interleave " > " (title : map snd ancestors))
    trimAncestors level = takeWhile (\(l, _) -> l < level)

-- | Intersperses a separator between list items (shared by the joiners above).
interleave :: String -> [String] -> [String]
interleave sep = foldr (\x acc -> if null acc then [x] else x : sep : acc) []

-- | The ATX heading's level and text, when the line is one.
headingOf :: String -> Maybe (Int, String)
headingOf line =
    let (hashes, rest) = span (== '#') line
        level = length hashes
     in case rest of
            (' ' : text)
                | level >= 1 && level <= 6 -> Just (level, trimBlank text)
            _ -> Nothing

-- | Drops a leading @---@ frontmatter block, if present.
stripFrontmatter :: String -> String
stripFrontmatter content =
    case lines content of
        (first : rest)
            | trim first == "---" ->
                case break ((== "---") . trim) rest of
                    (_, _ : body) -> unlines body
                    _ -> content
        _ -> content
  where
    trim = dropWhile (== ' ') . takeWhile (/= '\r')

-- | Trims leading and trailing blank space.
trimBlank :: String -> String
trimBlank = dropSpace . reverse . dropSpace . reverse
  where
    dropSpace = dropWhile (`elem` " \t\r\n")
