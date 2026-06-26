{- | Parent @index.md@ listing maintenance for move and delete (RFC-0027). A
folder's @index.md@ lists its members: subsections as grid cards inside a
@<div class="grid cards ...">@ block, flat pages as plain @- [Title](./page.md)@
bullets. When a page or section moves, its entry is /relocated/ -- removed from the
source listing and added to the destination's -- rather than repointed in place
(those two files are excluded from the generic link rewrite of
'MicroHttp.DocumentLinks.planMoveRewrites'); a delete removes the entry so it is
never counted as a blocking inbound reference.

The functions are pure over the @index.md@ text. Entry matching and link repointing
reuse the link engine, so an entry is matched by where its link /resolves/ (robust
to @./@ vs bare relative forms) and repointed with 'relativeBetween'.
-}
module MicroHttp.DocumentListing (
    removeListingEntry,
    addListingEntry,
) where

import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf, isPrefixOf)
import MicroHttp.DocumentLinks (
    linkEnd,
    linkStart,
    linkTarget,
    pageLinks,
    pathSegmentsOf,
    relativeBetween,
    resolveTarget,
    rewriteLinks,
    splitTargetSuffix,
 )

{- | Removes the listing entry (a single list-item line) whose inline link resolves,
from the @index.md@'s own directory @indexDir@, to @target@; returns the new text
and the removed line (without its newline), or the text unchanged and 'Nothing' when
no entry matches.
-}
removeListingEntry :: String -> String -> String -> (String, Maybe String)
removeListingEntry indexDir target text =
    case break (matchesTarget indexDir target) (textLines text) of
        (_, []) -> (text, Nothing)
        (before, removed : after) -> (joinLines (endsWithNewline text) (before ++ after), Just removed)

{- | Adds a listing entry to a destination @index.md@, repointing the entry's link
to reach @target@ from the destination directory @destDir@. A section entry (target
@.../index.md@) goes as a grid card before the grid block's closing @</div>@ (a grid
block is synthesised at end of file when absent); a flat page entry goes as a bullet
after the existing bullet run (or appended when none exists).
-}
addListingEntry :: String -> String -> String -> String -> String
addListingEntry destDir target entryLine text =
    joinLines (endsWithNewline text) (insert (textLines text))
  where
    newEntry = repointEntry destDir target entryLine
    insert ls
        | isSectionTarget target = insertCard newEntry ls
        | otherwise = insertBullet newEntry ls

-- | Repoints an entry's first inline link to reach @target@ from @destDir@, preserving its anchor suffix.
repointEntry :: String -> String -> String -> String
repointEntry destDir target line =
    -- The line is the byte-per-char form (from BS.unpack of the index.md bytes), so
    -- BS.pack/BS.unpack round-trips it losslessly while pageLinks/rewriteLinks work on bytes.
    let packed = BS.pack line
     in case pageLinks packed of
            [] -> line
            (l : _) ->
                let (_, suffix) = splitTargetSuffix (linkTarget l)
                 in BS.unpack (rewriteLinks packed [(linkStart l, linkEnd l, relativeBetween destDir target ++ suffix)])

{- | Inserts a card line into the first grid block, after the last existing card
(so cards stay contiguous and a trailing blank line before @</div>@ is preserved),
falling back to just before @</div>@ when the block has no cards yet, or to a fresh
block appended at end of file when there is no grid block.
-}
insertCard :: String -> [String] -> [String]
insertCard entry ls =
    case gridCloseIndex ls of
        Just close ->
            let at = case [i | (i, l) <- zip [0 ..] ls, i < close, isListItem l] of
                    [] -> close
                    items -> last items + 1
                (before, after) = splitAt at ls
             in before ++ [entry] ++ after
        Nothing -> ls ++ ["", "<div class=\"grid cards\" markdown>", "", entry, "", "</div>"]

-- | Inserts a bullet line after the last existing list-item line, or appends it (with a blank separator) when none.
insertBullet :: String -> [String] -> [String]
insertBullet entry ls =
    case lastListItemIndex ls of
        Just i -> let (before, after) = splitAt (i + 1) ls in before ++ [entry] ++ after
        Nothing -> ls ++ ["", entry]

-- | The index of the @</div>@ line that closes the first grid-cards block, if present.
gridCloseIndex :: [String] -> Maybe Int
gridCloseIndex ls =
    case break isGridOpen (zip [0 ..] ls) of
        (_, []) -> Nothing
        (_, (openIdx, _) : afterOpen) ->
            case filter (\(i, l) -> i > openIdx && isClosingDiv l) afterOpen of
                ((closeIdx, _) : _) -> Just closeIdx
                [] -> Nothing
  where
    isGridOpen (_, l) = "grid cards" `isInfixOf` l
    isClosingDiv l = "</div>" `isPrefixOf` dropSpaces l

-- | The index of the last list-item line, if any.
lastListItemIndex :: [String] -> Maybe Int
lastListItemIndex ls =
    case [i | (i, l) <- zip [0 ..] ls, isListItem l] of
        [] -> Nothing
        indices -> Just (last indices)

-- | Whether a target points at a section (its final path segment is @index.md@).
isSectionTarget :: String -> Bool
isSectionTarget target = case pathSegmentsOf (fst (splitTargetSuffix target)) of
    [] -> False
    segs -> last segs == "index.md"

-- | Whether a line is a Markdown list item (a @-@ bullet after optional indent).
isListItem :: String -> Bool
isListItem line = "- " `isPrefixOf` dropSpaces line

-- | Whether a line's inline link resolves (from @indexDir@) to @target@.
matchesTarget :: String -> String -> String -> Bool
matchesTarget indexDir target line =
    isListItem line && any (\l -> resolveTarget indexDir (linkTarget l) == Just target) (pageLinks (BS.pack line))

dropSpaces :: String -> String
dropSpaces = dropWhile (== ' ')

-- | The text split into lines, dropping a single trailing newline (re-added by 'joinLines').
textLines :: String -> [String]
textLines = lines

-- | Whether the text ends with a newline (so 'joinLines' can restore it).
endsWithNewline :: String -> Bool
endsWithNewline s = not (null s) && last s == '\n'

-- | Rejoins lines with @\\n@, restoring a trailing newline when the original had one.
joinLines :: Bool -> [String] -> String
joinLines trailing ls = unlines ls `dropFinalNewline` trailing
  where
    dropFinalNewline s True = s
    dropFinalNewline s False = if not (null s) && last s == '\n' then init s else s
