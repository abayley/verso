{- | Splits a page into search-index chunks (RFC-0034): one chunk per ATX
heading section (fence-aware, so a @#@ comment inside a code fence never
starts a section), each prefixed by a context line of the page title plus
ancestor heading path. Sections beyond the size cap split at paragraph
boundaries. Pure: the caller supplies the page title and the raw content
bytes.

The scan works over the UTF-8 bytes directly (libc @memchr@ finds the line
ends; classification reads a handful of bytes per line; sections and
paragraphs are O(1) views), so the page is never decoded to 'String' -- only
the short heading texts are. The size cap therefore counts bytes rather than
decoded characters: equivalent for the ASCII-dominant corpus, and the cap is
a soft budget in any case. On mhs the previous 'String' pipeline (decode,
per-line list churn) was a large share of the indexing cost
(@make bench-search-chunk@).
-}
module Verso.SearchChunks (
    Chunk (..),
    chunkPage,
    lineRanges,
    isDashesLine,
) where

import qualified Concordance.Utf8 as Utf8
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Ptr as Ptr
import qualified System.IO.Unsafe as Unsafe

foreign import ccall "string.h memchr" c_memchr :: CStr.CString -> CTypes.CInt -> CTypes.CSize -> IO (Ptr.Ptr ())

-- | One search-index chunk of a page.
data Chunk = Chunk
    { chunkAnchor :: String
    -- ^ The section's heading text; empty for the pre-heading preamble.
    , chunkSeq :: Int
    -- ^ The chunk's order within the page.
    , chunkText :: BS.ByteString
    -- ^ Context line plus section Markdown (frontmatter stripped), as UTF-8 bytes.
    }
    deriving (Eq, Show)

-- | A half-open byte range @[start, end)@ into the page content.
type Range = (Int, Int)

{- | Chunks a page: context line (title plus ancestor headings), heading
sections, size-capped (in bytes) at paragraph boundaries.
-}
chunkPage :: Int -> String -> BS.ByteString -> [Chunk]
chunkPage cap title content =
    [ Chunk anchor seqNo text
    | (seqNo, (anchor, text)) <- zip [0 ..] (concatMap capPieces usable)
    ]
  where
    usable = [s | s@(_, _, paras) <- sectionsOf title content (dropFrontmatter content (lineRanges content)), not (null paras)]
    capPieces (anchor, context, paras) =
        case splitAtParagraphs cap content paras of
            [] -> []
            (first : rest) ->
                (anchor, withContext context first)
                    : [(anchor, withContext (continuationContext anchor context) piece) | piece <- rest]
    continuationContext anchor context =
        if null anchor then context else context ++ " > " ++ anchor
    withContext context = BS.append (BS.pack (Utf8.encodeUtf8 (context ++ "\n")))

{- | Splits the paragraph ranges into pieces of at most the cap (in bytes) at
paragraph boundaries, joined with blank lines; a single paragraph beyond the
cap stays whole.
-}
splitAtParagraphs :: Int -> BS.ByteString -> [Range] -> [BS.ByteString]
splitAtParagraphs cap content = go
  where
    go [] = []
    go (p : ps) = accumulate (rangeLength p) [p] ps
    accumulate len accRev (p : ps)
        | len + 2 + rangeLength p <= cap = accumulate (len + 2 + rangeLength p) (p : accRev) ps
    accumulate _ accRev ps = joinParagraphs (reverse accRev) : go ps
    joinParagraphs ranges = BS.concat (List.intersperse blankSep (map (viewOf content) ranges))
    rangeLength (s, e) = e - s

blankSep :: BS.ByteString
blankSep = BS.pack "\n\n"

{- | The heading sections in line order, each carrying its heading text
(empty for the preamble), its context line (title plus @ > @-joined ancestor
heading path), and its paragraph ranges.
-}
sectionsOf :: String -> BS.ByteString -> [Range] -> [(String, String, [Range])]
sectionsOf title content = go False [] "" []
  where
    go _ ancestors anchor accRev [] = [emit ancestors anchor accRev]
    go inFence ancestors anchor accRev (l : ls)
        | isFenceAt content l = go (not inFence) ancestors anchor (l : accRev) ls
        | inFence = go inFence ancestors anchor (l : accRev) ls
        | otherwise =
            case headingAt content l of
                Just (level, text) ->
                    emit ancestors anchor accRev
                        : go False (takeWhile (\(lv, _) -> lv < level) ancestors ++ [(level, text)]) text [l] ls
                Nothing -> go False ancestors anchor (l : accRev) ls
    emit ancestors anchor accRev =
        ( anchor
        , contextOf (if null anchor then ancestors else init ancestors)
        , paragraphRanges content (reverse accRev)
        )
    contextOf ancestors = List.intercalate " > " (title : map snd ancestors)

{- | Groups a section's lines into paragraph ranges: blank lines outside code
fences separate paragraphs; each paragraph is a contiguous source range,
trimmed of leading and trailing blank space.
-}
paragraphRanges :: BS.ByteString -> [Range] -> [Range]
paragraphRanges content = go False []
  where
    go _ accRev [] = emit accRev
    go inFence accRev (l : ls)
        | isFenceAt content l = go (not inFence) (l : accRev) ls
        | not inFence && isBlankAt content l = emit accRev ++ go False [] ls
        | otherwise = go inFence (l : accRev) ls
    emit [] = []
    emit accRev =
        let end = snd (head accRev)
            start = fst (List.last accRev)
            trimmed@(s, e) = trimRange content (start, end)
         in [trimmed | s < e]

-- | Drops a leading @---@ frontmatter block from the line list, if present.
dropFrontmatter :: BS.ByteString -> [Range] -> [Range]
dropFrontmatter content allLines@(first : rest)
    | isDashesLine content first =
        case break (isDashesLine content) rest of
            (_, _ : body) -> body
            _ -> allLines
dropFrontmatter _ allLines = allLines

{- | The page's lines as byte ranges (excluding the newline), with 'lines'
semantics (no empty final line after a trailing newline). The line ends come
from libc @memchr@ so the interpreter never walks the bytes between them.
-}
lineRanges :: BS.ByteString -> [Range]
lineRanges content = Unsafe.unsafePerformIO $
    BS.useAsCStringLen content $ \(basePtr, len) -> do
        let findNewline i
                | i >= len = pure Nothing
                | otherwise = do
                    p <- c_memchr (Ptr.plusPtr basePtr i) 10 (fromIntegral (len - i))
                    pure (if p == Ptr.nullPtr then Nothing else Just (Ptr.minusPtr p basePtr))
            go start
                | start >= len = pure []
                | otherwise = do
                    newline <- findNewline start
                    case newline of
                        Nothing -> pure [(start, len)]
                        Just j -> ((start, j) :) <$> go (j + 1)
        go 0

-- | The bytes of a range as an O(1) view.
viewOf :: BS.ByteString -> Range -> BS.ByteString
viewOf content (s, e) = BS.take (e - s) (BS.drop s content)

-- | Shrinks a range past leading and trailing blank space (@ \t\r\n@).
trimRange :: BS.ByteString -> Range -> Range
trimRange content (s0, e0) = (advance s0, retreat e0)
  where
    advance s
        | s < e0 && isBlankByte (BS.index content s) = advance (s + 1)
        | otherwise = s
    retreat e
        | e > s0 && isBlankByte (BS.index content (e - 1)) = retreat (e - 1)
        | otherwise = e

isBlankByte :: Char -> Bool
isBlankByte c = c == ' ' || c == '\t' || c == '\r' || c == '\n'

-- | Whether the line is blank (spaces, tabs, and carriage returns only).
isBlankAt :: BS.ByteString -> Range -> Bool
isBlankAt content (s, e) = go s
  where
    go i = i >= e || (isBlankByte (BS.index content i) && go (i + 1))

-- | Whether the line opens or closes a code fence (``` after optional indent).
isFenceAt :: BS.ByteString -> Range -> Bool
isFenceAt content (s, e) = go s
  where
    go k
        | k < e && BS.index content k == ' ' = go (k + 1)
        | otherwise =
            k + 2 < e
                && BS.index content k == '`'
                && BS.index content (k + 1) == '`'
                && BS.index content (k + 2) == '`'

{- | Whether the line is a frontmatter delimiter: @---@ alone on the line,
with spaces, tabs, and a carriage return tolerated on either side. One rule
for the search chunker and 'Verso.Frontmatter'.
-}
isDashesLine :: BS.ByteString -> Range -> Bool
isDashesLine content (s, e) = dashes (skipBlanks s)
  where
    dashes k =
        k + 3 <= e
            && BS.index content k == '-'
            && BS.index content (k + 1) == '-'
            && BS.index content (k + 2) == '-'
            && skipBlanks (k + 3) == e
    -- Past any run of spaces, tabs, and carriage returns from k.
    skipBlanks k
        | k < e && (BS.index content k == ' ' || BS.index content k == '\t' || BS.index content k == '\r') = skipBlanks (k + 1)
        | otherwise = k

-- | The ATX heading's level and (decoded, trimmed) text, when the line is one.
headingAt :: BS.ByteString -> Range -> Maybe (Int, String)
headingAt content (s, e) =
    let level = countHashes s
     in if level >= 1 && level <= 6 && s + level < e && BS.index content (s + level) == ' '
            then Just (level, decodeRange (trimRange content (s + level + 1, e)))
            else Nothing
  where
    countHashes k
        | k < e && BS.index content k == '#' = 1 + countHashes (k + 1)
        | otherwise = 0
    decodeRange range = Utf8.decodeUtf8 (BS.unpack (viewOf content range))
