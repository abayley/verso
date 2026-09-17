{- | A document's leading frontmatter block: the lines between an opening and a
closing @---@ line at the top of the file, and the @name@ scalar inside it that
serves as the page title.

One definition of the block serves every reader (RFC-0039). 'leadingBlock'
classifies bytes already in hand; 'slice' is its closed-block-or-empty form;
'blockI' is the same test as an early-completing iteratee, so 'readBlock' can
stream a file and stop at the closing delimiter without reading the body.
Delimiter lines follow 'PageLines.isDashesLine': @---@ with surrounding
blanks tolerated, nothing else on the line.
-}
module Verso.Frontmatter (
    Lead (..),
    leadingBlock,
    slice,
    title,
    titleOf,
    blockI,
    blockCapBytes,
    readBlock,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8
import qualified Verso.PageLines as PageLines

-- | Where a document's leading frontmatter stands in the bytes seen so far.
data Lead
    = -- | The content does not open with a delimiter line.
      NoFrontmatter
    | -- | It opens with a delimiter but no closing delimiter has been seen.
      Unclosed
    | -- | The block, both delimiter lines included (the closing line's newline excluded).
      Frontmatter BS.ByteString
    deriving (Eq, Show)

{- | Classifies the leading frontmatter of some content. In 'IO' because the line
ends come from a foreign @memchr@ scan (ADR-0087); a pure split would unpack the
whole content on MicroHs, which is the cost RFC-0039 removed.
-}
leadingBlock :: BS.ByteString -> IO Lead
leadingBlock content = do
    ranges <- PageLines.lineRanges content
    pure $ case ranges of
        (first : rest)
            | PageLines.isDashesLine content first ->
                case List.find (PageLines.isDashesLine content) rest of
                    Just (_, closeEnd) -> Frontmatter (BS.take closeEnd content)
                    Nothing -> Unclosed
        _ -> NoFrontmatter

{- | The closed frontmatter block of content already in hand, else empty. A
caller with the whole document decodes just this slice for the title.
-}
slice :: BS.ByteString -> IO BS.ByteString
slice content = do
    lead <- leadingBlock content
    pure $ case lead of
        Frontmatter block -> block
        _ -> BS.empty

{- | Reads the leading frontmatter block as a stream consumer, completing as
soon as the closing delimiter has been seen so the producer stops feeding
(and closes the file). Completes with empty when the content does not open
with a delimiter, at end of stream, or once an unclosed block has grown past
'blockCapBytes' -- the carry is bounded, so a document with no closing
delimiter is never read whole.
-}
blockI :: Iteratee.Iter e BS.ByteString
blockI = go 0 []
  where
    go seen acc = Iteratee.NeedInput (step seen acc)
    step seen acc stream = case stream of
        Iteratee.Chunk bytes
            | BS.null bytes -> go seen acc
            | otherwise -> Iteratee.IterM $ do
                let acc' = bytes : acc
                    seen' = seen + BS.length bytes
                lead <- leadingBlock (BS.concat (reverse acc'))
                pure $ case lead of
                    Frontmatter block -> done block
                    NoFrontmatter -> done BS.empty
                    Unclosed
                        | seen' > blockCapBytes -> done BS.empty
                        | otherwise -> go seen' acc'
        Iteratee.EndOfStream Nothing -> done BS.empty
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err stream
    done block = Iteratee.Done block (Iteratee.Chunk BS.empty)

-- | The most bytes 'blockI' reads into an unclosed block before giving up.
blockCapBytes :: Int
blockCapBytes = 65536

{- | Streams a file just far enough to read its leading frontmatter block;
empty for a file that is missing, unreadable, or has no closed block.
-}
readBlock :: FilePath -> IO BS.ByteString
readBlock path = do
    outcome <- Stream.fileEnumerator path blockI >>= Iteratee.run
    case outcome of
        Right block -> pure block
        Left _ -> pure BS.empty

-- | 'title' over the block's UTF-8 bytes (RFC-0043): the name as real characters.
titleOf :: BS.ByteString -> Maybe String
titleOf = title . Utf8.decodeBytes

-- | The @name@ field from a document's leading frontmatter block (unquoted), or Nothing.
title :: String -> Maybe String
title content =
    case map stripCarriageReturn (lines content) of
        (first : rest)
            | trimSpace first == "---" -> findName (takeWhile (\l -> trimSpace l /= "---") rest)
        _ -> Nothing
  where
    findName [] = Nothing
    findName (l : ls) = case nameFieldValue l of
        Just value -> Just value
        Nothing -> findName ls

-- | The unquoted value of a @name:@ line, or Nothing for any other line.
nameFieldValue :: String -> Maybe String
nameFieldValue line = case break (== ':') (dropWhile Char.isSpace line) of
    ("name", ':' : rest) -> Just (unquoteScalar (trimSpace rest))
    _ -> Nothing

-- | Strips a surrounding double- or single-quoted YAML scalar, unescaping as that style requires.
unquoteScalar :: String -> String
unquoteScalar value
    | wrapped '"' = unescapeDouble middle
    | wrapped '\'' = undoubleSingle middle
    | otherwise = value
  where
    wrapped q = length value >= 2 && head value == q && last value == q
    middle = init (drop 1 value)
    unescapeDouble ('\\' : c : xs) = c : unescapeDouble xs
    unescapeDouble (c : xs) = c : unescapeDouble xs
    unescapeDouble [] = []
    undoubleSingle ('\'' : '\'' : xs) = '\'' : undoubleSingle xs
    undoubleSingle (c : xs) = c : undoubleSingle xs
    undoubleSingle [] = []

-- | Trims leading and trailing whitespace.
trimSpace :: String -> String
trimSpace = f . f where f = reverse . dropWhile Char.isSpace

-- | Drops a trailing carriage return (CRLF tolerance).
stripCarriageReturn :: String -> String
stripCarriageReturn s = if not (null s) && last s == '\r' then init s else s
