{- | Byte-string scans that never widen their input to a list.

Under MicroHs almost every non-primitive 'Data.ByteString' function is
@Data.List.f . unpack@: @elemIndex@, @findIndex@, @elem@, @notElem@, @any@,
@all@, @split@, @lines@, @isInfixOf@, @foldl'@ and their Char8 wrappers all build
a list of every byte and scan it. That is O(n) per call, and worse: the scan's
in-progress state is one unevaluated application per element, and the runtime's
collector marks the live graph on the evaluator's fixed 250,000-slot stack, one
slot per such node. A collection landing during a scan of more than ~250KB kills
the process with @stack overflow@ (RFC-0040 phase 2, baseline ref). The scans here
are strict index loops over 'BS.index', which is an O(1) view: they force their
index each step and hold nothing per element, so they mark in constant stack and
allocate only their results.

Use these for any value that can be document- or corpus-sized: a request body, a
page, a persisted index. A request line or a chunk carry is bounded and may keep
the library functions.
-}
module MicroHttp.Bytes (
    indexOf,
    split,
    isInfixOf,
    foldl',
    concatBalanced,
    intercalate,
) where

import qualified Data.List as List

import qualified Data.ByteString.Char8 as BS

-- | The index of the first occurrence of a byte, or 'Nothing'.
indexOf :: Char -> BS.ByteString -> Maybe Int
indexOf = indexFrom 0

-- | The index of the first occurrence of a byte at or after @start@, or 'Nothing'.
indexFrom :: Int -> Char -> BS.ByteString -> Maybe Int
indexFrom start c bytes = go start
  where
    len = BS.length bytes
    go i
        | i >= len = Nothing
        | BS.index bytes i == c = Just i
        | otherwise = go (i + 1)

{- | Splits on a separator byte into O(1) views, with 'BS.split''s semantics: the
separator is dropped, adjacent separators yield empty pieces, a trailing
separator yields a trailing empty piece, and empty input yields no pieces.
-}
split :: Char -> BS.ByteString -> [BS.ByteString]
split c bytes
    | BS.null bytes = []
    | otherwise = go 0
  where
    len = BS.length bytes
    go start = case indexFrom start c bytes of
        Nothing -> [BS.drop start bytes]
        Just i -> BS.take (i - start) (BS.drop start bytes) : if i + 1 > len then [] else go (i + 1)

{- | Whether the needle occurs anywhere in the haystack, with 'BS.isInfixOf''s
semantics (an empty needle is always found). Each candidate position is found by
scanning for the needle's first byte and confirmed by comparing an O(1) view with
the primitive equality, so the haystack is never widened; the cost is linear in
the haystack for the short needles this serves (a link prefix, a marker).
-}
isInfixOf :: BS.ByteString -> BS.ByteString -> Bool
isInfixOf needle hay
    | BS.null needle = True
    | otherwise = go 0
  where
    needleLen = BS.length needle
    lastStart = BS.length hay - needleLen
    first = BS.index needle 0
    go start
        | start > lastStart = False
        | otherwise = case indexFrom start first hay of
            Nothing -> False
            Just i
                | i > lastStart -> False
                | BS.take needleLen (BS.drop i hay) == needle -> True
                | otherwise -> go (i + 1)

-- | A strict left fold over the bytes, forcing the accumulator at every step.
foldl' :: (a -> Char -> a) -> a -> BS.ByteString -> a
foldl' f z bytes = go 0 z
  where
    len = BS.length bytes
    go i acc
        | i >= len = acc
        | otherwise = let acc' = f acc (BS.index bytes i) in acc' `seq` go (i + 1) acc'

{- | Joins pieces with pairwise appends, O(total x log pieces) bytes copied. The
library's @concat@ is @foldr append@, which re-copies the growing result once per
piece (O(total x pieces)); its @intercalate@ unpacks every piece to a list. Use
this to join the lines of a paragraph, the paragraphs of a chunk, or any list
whose length grows with the input (RFC-0043).
-}
concatBalanced :: [BS.ByteString] -> BS.ByteString
concatBalanced pieces = case pieces of
    [] -> BS.empty
    [one] -> one
    _ -> concatBalanced (pairUp pieces)
  where
    pairUp (a : b : rest) = BS.append a b : pairUp rest
    pairUp rest = rest

-- | 'concatBalanced' with a separator between the pieces; never unpacks.
intercalate :: BS.ByteString -> [BS.ByteString] -> BS.ByteString
intercalate separator = concatBalanced . List.intersperse separator
