{-# LANGUAGE TupleSections #-}

{- | The BERT WordPiece tokeniser for the Concordance search engine
(RFC-0034): pure text-to-token-ids encoding against an injected vocabulary,
matching the tokenisation of the BERT-family embedding models
(bert-base-uncased vocab, lowercased, accent-stripped). The vocabulary is
supplied as the raw bytes of a @vocab.txt@ (one piece per line, id = line
position); no IO happens here.
-}
module Concordance.WordPiece (
    Vocab,
    mkVocab,
    Encoded (..),
    encode,
    encodeMany,
) where

import qualified Concordance.Utf8 as Utf8
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Bytes as Bytes

{- | A WordPiece vocabulary as two character tries: word-start pieces and
@##@ continuation pieces (stored with the @##@ stripped). A trie makes the
greedy longest-match walk O(word length) with cheap per-'Char' map steps;
the previous @Map String Int@ paid a full string-keyed lookup per candidate
length per word, which dominated the whole indexing pipeline
(@make bench-search-chunk@).
-}
data Vocab = Vocab
    { vocabStart :: Trie
    , vocabContinuation :: Trie
    }

-- | A character trie: the piece id ending at this node (if any) and the children.
data Trie = Trie (Maybe Int) (Map.Map Char Trie)

emptyTrie :: Trie
emptyTrie = Trie Nothing Map.empty

-- | Inserts a piece; a duplicate piece keeps the later id (matching Map.fromList).
insertTrie :: String -> Int -> Trie -> Trie
insertTrie [] tokenId (Trie _ children) = Trie (Just tokenId) children
insertTrie (c : cs) tokenId (Trie value children) =
    Trie value (Map.insert c (insertTrie cs tokenId (Map.findWithDefault emptyTrie c children)) children)

-- | The id stored for exactly this piece, if present.
exactLookup :: Trie -> String -> Maybe Int
exactLookup (Trie value _) [] = value
exactLookup (Trie _ children) (c : cs) = Map.lookup c children >>= \child -> exactLookup child cs

-- | An encoded sequence: token ids and the matching attention mask.
data Encoded = Encoded
    { encodedIds :: [Int]
    , encodedMask :: [Int]
    }
    deriving (Eq, Show)

{- | Builds a vocabulary from the raw bytes of a @vocab.txt@: one piece per
line, the token id being the zero-based line position. Empty lines are
skipped (an empty piece could otherwise match without consuming input).
-}
mkVocab :: BS.ByteString -> Vocab
mkVocab bytes = List.foldl' add (Vocab emptyTrie emptyTrie) pieces
  where
    pieces = zip (map (Utf8.decodeUtf8 . BS.unpack) (Bytes.split '\n' bytes)) [0 ..]
    add vocab ('#' : '#' : rest, tokenId)
        | not (null rest) =
            vocab{vocabContinuation = insertTrie rest tokenId (vocabContinuation vocab)}
    add vocab (piece, tokenId)
        | null piece = vocab
        | otherwise = vocab{vocabStart = insertTrie piece tokenId (vocabStart vocab)}

-- | Looks up a piece's token id (word-start spelling, as the specials use).
pieceId :: Vocab -> String -> Maybe Int
pieceId vocab = exactLookup (vocabStart vocab)

{- | Encodes UTF-8 text as a BERT input sequence: @[CLS]@, the text's word
pieces, @[SEP]@, capped at the given total token budget. The attention mask
is all ones (no padding is produced).

The walk runs directly over the bytes: each character is decoded and
normalised on the fly, whitespace and punctuation delimit tokens (the BERT
basic-tokeniser rules), and words feed the trie in place -- no intermediate
decoded 'String', word list, or token list is ever built. On mhs that
intermediate churn was most of the search-indexing cost
(@make bench-search-chunk@).
-}
encode :: Vocab -> Int -> BS.ByteString -> Encoded
encode vocab cap text = fst (encodeCached vocab cap Map.empty text)

{- | Encodes several texts (a page's chunks), sharing one word -> piece-ids
cache across them: a page repeats its words heavily across chunks, and the
cache key is the word's raw byte view, whose comparison is an mhs primitive
(@bscmp@) -- unlike the 'String'-keyed memo this replaces, the lookup is far
cheaper than re-walking the trie.
-}
encodeMany :: Vocab -> Int -> [BS.ByteString] -> [Encoded]
encodeMany vocab cap = go Map.empty
  where
    go _ [] = []
    go cache (text : rest) =
        let (encoded, cache') = encodeCached vocab cap cache text
         in encoded : go cache' rest

-- | The word cache: raw word bytes to piece ids.
type PieceCache = Map.Map BS.ByteString [Int]

-- | One text's encoding, threading the shared word cache.
encodeCached :: Vocab -> Int -> PieceCache -> BS.ByteString -> (Encoded, PieceCache)
encodeCached vocab cap cache0 text =
    let (pieces, cacheOut) = scan (cap - 2) cache0 0
        ids = specialId vocab "[CLS]" : pieces ++ [specialId vocab "[SEP]"]
     in (Encoded ids (map (const 1) ids), cacheOut)
  where
    len = BS.length text
    unkId = specialId vocab "[UNK]"

    -- The decoded char at byte i and its width (permissive, mirroring Utf8.decodeUtf8).
    charAt i =
        let b0 = BS.index text i
            n0 = Char.ord b0
            contAt k = Char.ord (BS.index text (i + k))
            multi n lead =
                let ok = i + n < len && all (\k -> let x = contAt k in x >= 0x80 && x < 0xC0) [1 .. n]
                 in if ok
                        then (Char.chr (List.foldl' (\acc k -> acc * 64 + (contAt k - 0x80)) lead [1 .. n]), n + 1)
                        else (b0, 1)
         in if n0 < 0x80
                then (b0, 1)
                else
                    if n0 >= 0xC0 && n0 < 0xE0
                        then multi 1 (n0 - 0xC0)
                        else
                            if n0 >= 0xE0 && n0 < 0xF0
                                then multi 2 (n0 - 0xE0)
                                else if n0 >= 0xF0 && n0 < 0xF8 then multi 3 (n0 - 0xF0) else (b0, 1)

    -- The normalised (lowercased, accent-folded) char at byte i and its width.
    -- ASCII (the overwhelming majority) short-circuits the decode and fold machinery.
    normAt i =
        let b = BS.index text i
         in if b <= '\127'
                then (if Char.isAsciiUpper b then Char.chr (Char.ord b + 32) else b, 1)
                else let (c, w) = charAt i in (foldAccent (Char.toLower c), w)

    -- The token-id stream from byte i (at most budget ids), and the updated cache.
    scan budget cache i
        | budget <= 0 || i >= len = ([], cache)
        | otherwise =
            let (c, w) = normAt i
             in if isSpaceChar c
                    then scan budget cache (i + w)
                    else
                        if isPunct c
                            then emit budget [singlePieceId c] cache (i + w)
                            else
                                let (wordTo, wordChars) = wordEnd (i + w) 1
                                    key = BS.take (wordTo - i) (BS.drop i text)
                                 in case Map.lookup key cache of
                                        Just ids -> emit budget ids cache wordTo
                                        Nothing ->
                                            let ids = wordIds i wordTo wordChars
                                             in emit budget ids (Map.insert key ids cache) wordTo

    emit budget ids cache i =
        let (rest, cache') = scan (budget - length ids) cache i
         in (take budget ids ++ rest, cache')

    -- The word's end byte and char count, scanning from byte j (n chars consumed).
    wordEnd j n
        | j >= len = (j, n)
        | otherwise =
            let (c, w) = normAt j
             in if isSpaceChar c || isPunct c then (j, n) else wordEnd (j + w) (n + 1)

    -- A single punctuation char's piece id ([UNK] when the vocab lacks it).
    singlePieceId c = case vocabStart vocab of
        Trie _ children -> case Map.lookup c children of
            Just (Trie (Just tokenId) _) -> tokenId
            _ -> unkId

    -- A word's piece ids over bytes [from, to): greedy longest match, [UNK] on any failure.
    wordIds from to chars
        | chars > maxWordLength = [unkId]
        | otherwise = Maybe.fromMaybe [unkId] (go (vocabStart vocab) from)
      where
        go trie j = do
            (tokenId, j') <- longest trie j Nothing
            if j' >= to then Just [tokenId] else (tokenId :) <$> go (vocabContinuation vocab) j'
        longest (Trie _ children) j best
            | j >= to = best
            | otherwise =
                let (c, w) = normAt j
                 in case Map.lookup c children of
                        Nothing -> best
                        Just child@(Trie value _) ->
                            longest child (j + w) (maybe best (\tokenId -> Just (tokenId, j + w)) value)

-- | The exact ASCII whitespace set of 'Char.isSpace', with the Unicode fallback.
isSpaceChar :: Char -> Bool
isSpaceChar c
    | c <= '\127' = c == ' ' || (c >= '\t' && c <= '\r')
    | otherwise = Char.isSpace c

{- | BERT's punctuation test: ASCII punctuation plus Unicode P\/S categories.
ASCII answers with range tests (the four ASCII punctuation\/symbol runs --
identical to @isPunctuation || isSymbol@ over ASCII) because mhs's Unicode
general-category test costs ~200 cells per character, which dominated the
tokenise pass (@make bench-search-chunk@).
-}
isPunct :: Char -> Bool
isPunct c
    | c <= '\127' =
        (c >= '!' && c <= '/')
            || (c >= ':' && c <= '@')
            || (c >= '[' && c <= '`')
            || (c >= '{' && c <= '~')
    | otherwise = Char.isPunctuation c || Char.isSymbol c

{- | Folds one lowercased character's accent away, if it has one. ASCII (the
overwhelming majority of corpus text) short-circuits before the table lookup.
-}
foldAccent :: Char -> Char
foldAccent c
    | c <= '\127' = c
    | otherwise = Maybe.fromMaybe c (Map.lookup c accentTable)

-- | Common Latin accented letters (lowercase) to their base letters.
accentTable :: Map.Map Char Char
accentTable =
    Map.fromList (concatMap expand groups)
  where
    expand (base, accented) = map (,base) accented
    groups =
        [ ('a', "\224\225\226\227\228\229\257")
        , ('c', "\231\269")
        , ('e', "\232\233\234\235\275\283")
        , ('i', "\236\237\238\239\299")
        , ('n', "\241\328")
        , ('o', "\242\243\244\245\246\333")
        , ('u', "\249\250\251\252\363")
        , ('y', "\253\255")
        , ('s', "\353")
        , ('z', "\382\380\378")
        ]

-- | BERT's per-word character limit: longer words become @[UNK]@ unmatched.
maxWordLength :: Int
maxWordLength = 100

-- | A special token's id; the vocabulary must contain it.
specialId :: Vocab -> String -> Int
specialId vocab piece =
    case pieceId vocab piece of
        Just tokenId -> tokenId
        Nothing -> error ("Concordance.WordPiece: vocabulary lacks " ++ piece)
