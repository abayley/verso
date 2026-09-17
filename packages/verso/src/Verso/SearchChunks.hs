{- | Splits a page into search-index chunks (RFC-0034): one chunk per ATX
heading section (fence-aware, so a @#@ comment inside a code fence never
starts a section), each prefixed by a context line of the page title plus
ancestor heading path. Sections beyond the size cap split at paragraph
boundaries. Pure: the caller supplies the page title and the raw content
bytes.

The chunker is a line-fed state machine ('feedLine', 'finish'), so the same
code chunks a page held whole ('chunkPage': libc @memchr@ finds the line ends
and each line is an O(1) view) and a page streamed from disk ('chunkFile',
RFC-0043: one read block plus the open paragraph and the open piece are all
that is ever live, whatever the page's size). Classification reads a handful
of bytes per line and the page is never decoded to 'String' -- only the short
heading texts are. The size cap therefore counts bytes rather than decoded
characters: equivalent for the ASCII-dominant corpus, and the cap is a soft
budget in any case. On mhs the previous 'String' pipeline (decode, per-line
list churn) was a large share of the indexing cost (@make bench-search-chunk@).
-}
module Verso.SearchChunks (
    Chunk (..),
    chunkPage,
    chunkFile,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.Bytes as Bytes
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8
import qualified Verso.PageLines as PageLines

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

{- | Chunks a page held whole: context line (title plus ancestor headings),
heading sections, size-capped (in bytes) at paragraph boundaries. The lines
are O(1) views fed to the same machine 'chunkFile' drives from disk.
-}
chunkPage :: Int -> String -> BS.ByteString -> IO [Chunk]
chunkPage cap title content = do
    ranges <- PageLines.lineRanges content
    pure (finish (List.foldl' feedLine (newChunker cap title) (map (PageLines.viewOf content) ranges)))

{- | Chunks a page streamed from disk (RFC-0043): the file is read in blocks
and fed to the machine one line at a time, so the page is never held whole.
A file that will not open is the fold's 'Stream.StreamError'.
-}
chunkFile :: Int -> String -> FilePath -> IO (Either Stream.StreamError [Chunk])
chunkFile cap title path =
    fmap finish <$> Stream.foldFileLines (\ck line -> pure (feedLine ck line)) (newChunker cap title) path

{- | The chunking state between lines. Paragraph lines and the open piece's
paragraphs accumulate in reverse; emitted pieces likewise, as (anchor, text).
-}
data Chunker = Chunker
    { ckCap :: Int
    , ckTitle :: String
    , ckFront :: Front
    , ckInFence :: Bool
    , ckAncestors :: [(Int, String)]
    -- ^ The open heading path, outermost first, including the current section's heading.
    , ckAnchor :: String
    , ckContext :: String
    -- ^ The current section's context line: title plus ancestor headings, without its own.
    , ckLines :: [BS.ByteString]
    -- ^ The open paragraph's lines, reversed.
    , ckPieceParas :: [BS.ByteString]
    -- ^ The open piece's paragraphs, reversed.
    , ckPieceLen :: Int
    -- ^ The open piece's byte length once joined (0 when empty).
    , ckPieceFirst :: Bool
    -- ^ Whether the open piece is its section's first (a later one carries a continuation context).
    , ckOut :: [(String, BS.ByteString)]
    }

{- | Where the machine is with respect to a leading frontmatter block: at the
first line; inside an opened block, holding its lines in case it never closes
(a whole-page chunker keeps an unclosed block as content, so this does too, up
to 'frontmatterCapBytes'); or past it.
-}
data Front = AtStart | Buffering [BS.ByteString] Int | Body

newChunker :: Int -> String -> Chunker
newChunker cap title = Chunker cap title AtStart False [] "" title [] [] 0 True []

{- | The most bytes held back for an unclosed frontmatter block before the
held lines are replayed as content. The whole-page form has no such bound,
so the two differ only for a page that opens with @---@, never closes it,
and runs past this size.
-}
frontmatterCapBytes :: Int
frontmatterCapBytes = 65536

-- | Feeds one line (without its newline) to the machine.
feedLine :: Chunker -> BS.ByteString -> Chunker
feedLine ck line = case ckFront ck of
    AtStart
        | PageLines.isDashesLine line (whole line) -> ck{ckFront = Buffering [line] (BS.length line)}
        | otherwise -> bodyLine ck{ckFront = Body} line
    Buffering held heldBytes
        | PageLines.isDashesLine line (whole line) -> ck{ckFront = Body}
        | heldBytes > frontmatterCapBytes -> bodyLine (replay ck held) line
        | otherwise -> ck{ckFront = Buffering (line : held) (heldBytes + BS.length line)}
    Body -> bodyLine ck line
  where
    replay ck0 held = List.foldl' bodyLine ck0{ckFront = Body} (reverse held)

-- | A line of the page body: a fence toggle, a heading (outside a fence), a blank (outside a fence), or text.
bodyLine :: Chunker -> BS.ByteString -> Chunker
bodyLine ck line
    | isFenceAt line (whole line) = (addLine ck line){ckInFence = not (ckInFence ck)}
    | ckInFence ck = addLine ck line
    | otherwise = case headingAt line (whole line) of
        Just (level, text) -> addLine (startSection (endSection ck) level text) line
        Nothing
            | isBlankAt line (whole line) -> endParagraph ck
            | otherwise -> addLine ck line

addLine :: Chunker -> BS.ByteString -> Chunker
addLine ck line = ck{ckLines = line : ckLines ck}

-- | Opens the section under a heading: the ancestor path is cut back to levels above it and the heading appended.
startSection :: Chunker -> Int -> String -> Chunker
startSection ck level text =
    let above = takeWhile (\(lv, _) -> lv < level) (ckAncestors ck)
     in ck
            { ckAncestors = above ++ [(level, text)]
            , ckAnchor = text
            , ckContext = List.intercalate " > " (ckTitle ck : map snd above)
            , ckPieceFirst = True
            }

-- | Closes the open paragraph and emits the open piece, if any.
endSection :: Chunker -> Chunker
endSection ck = emitPiece (endParagraph ck)

{- | Closes the open paragraph: its lines joined with newlines and trimmed of
blank space at both ends join the open piece if they fit under the cap, else
the piece is emitted and a new one starts with them. A blank paragraph is
dropped. The whole-page form's greedy paragraph packing, one step at a time.
-}
endParagraph :: Chunker -> Chunker
endParagraph ck
    | null (ckLines ck) = ck
    | BS.null paragraph = ck{ckLines = []}
    | ckPieceLen ck == 0 = ck{ckLines = [], ckPieceParas = [paragraph], ckPieceLen = plen}
    | ckPieceLen ck + 2 + plen <= ckCap ck = ck{ckLines = [], ckPieceParas = paragraph : ckPieceParas ck, ckPieceLen = ckPieceLen ck + 2 + plen}
    | otherwise = (emitPiece ck){ckLines = [], ckPieceParas = [paragraph], ckPieceLen = plen}
  where
    joined = Bytes.intercalate newline (reverse (ckLines ck)) -- never the library intercalate: it unpacks every line
    paragraph = trimBlank joined
    plen = BS.length paragraph

-- | Emits the open piece under the section's context (a continuation context after the first), if it has any paragraph.
emitPiece :: Chunker -> Chunker
emitPiece ck
    | null (ckPieceParas ck) = ck
    | otherwise =
        let context
                | ckPieceFirst ck || null (ckAnchor ck) = ckContext ck
                | otherwise = ckContext ck ++ " > " ++ ckAnchor ck
            text = BS.append (BS.pack (Utf8.encodeUtf8 (context ++ "\n"))) (Bytes.intercalate blankSep (reverse (ckPieceParas ck)))
         in ck{ckOut = (ckAnchor ck, text) : ckOut ck, ckPieceParas = [], ckPieceLen = 0, ckPieceFirst = False}

-- | Ends the page: an unclosed frontmatter block is content, the last paragraph and piece are emitted, and the chunks are numbered.
finish :: Chunker -> [Chunk]
finish ck0 =
    let ck = case ckFront ck0 of
            Buffering held _ -> List.foldl' bodyLine ck0{ckFront = Body} (reverse held)
            _ -> ck0
        done = endSection ck
     in [Chunk anchor seqNo text | (seqNo, (anchor, text)) <- zip [0 ..] (reverse (ckOut done))]

-- | The range covering a whole line.
whole :: BS.ByteString -> PageLines.Range
whole line = (0, BS.length line)

newline :: BS.ByteString
newline = BS.pack "\n"

blankSep :: BS.ByteString
blankSep = BS.pack "\n\n"

-- | The bytes past leading and trailing blank space (@ \t\r\n@), as a view.
trimBlank :: BS.ByteString -> BS.ByteString
trimBlank bytes = PageLines.viewOf bytes (trimRange bytes (0, BS.length bytes))

-- | Shrinks a range past leading and trailing blank space (@ \t\r\n@).
trimRange :: BS.ByteString -> PageLines.Range -> PageLines.Range
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
isBlankAt :: BS.ByteString -> PageLines.Range -> Bool
isBlankAt content (s, e) = go s
  where
    go i = i >= e || (isBlankByte (BS.index content i) && go (i + 1))

-- | Whether the line opens or closes a code fence (``` after optional indent).
isFenceAt :: BS.ByteString -> PageLines.Range -> Bool
isFenceAt content (s, e) = go s
  where
    go k
        | k < e && BS.index content k == ' ' = go (k + 1)
        | otherwise =
            k + 2 < e
                && BS.index content k == '`'
                && BS.index content (k + 1) == '`'
                && BS.index content (k + 2) == '`'

-- | The ATX heading's level and (decoded, trimmed) text, when the line is one.
headingAt :: BS.ByteString -> PageLines.Range -> Maybe (Int, String)
headingAt content (s, e) =
    let level = countHashes s
     in if level >= 1 && level <= 6 && s + level < e && BS.index content (s + level) == ' '
            then Just (level, decodeRange (trimRange content (s + level + 1, e)))
            else Nothing
  where
    countHashes k
        | k < e && BS.index content k == '#' = 1 + countHashes (k + 1)
        | otherwise = 0
    decodeRange range = Utf8.decodeUtf8 (BS.unpack (PageLines.viewOf content range))
