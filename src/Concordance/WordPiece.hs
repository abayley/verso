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
) where

import qualified Concordance.Utf8 as Utf8
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Maybe as Maybe

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

{- | The longest piece in the trie that prefixes the word (consuming at least
one character), with the unconsumed remainder.
-}
longestMatch :: Trie -> String -> Maybe (Int, String)
longestMatch trie word = case word of
    [] -> Nothing
    (c : cs) -> descend trie Nothing c cs
  where
    descend (Trie _ children) best c cs =
        case Map.lookup c children of
            Nothing -> best
            Just child@(Trie value _) ->
                let best' = maybe best (\tokenId -> Just (tokenId, cs)) value
                 in case cs of
                        [] -> best'
                        (c' : cs') -> descend child best' c' cs'

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
    pieces = zip (map (Utf8.decodeUtf8 . BS.unpack) (BS.split '\n' bytes)) [0 ..]
    add vocab ('#' : '#' : rest, tokenId)
        | not (null rest) =
            vocab{vocabContinuation = insertTrie rest tokenId (vocabContinuation vocab)}
    add vocab (piece, tokenId)
        | null piece = vocab
        | otherwise = vocab{vocabStart = insertTrie piece tokenId (vocabStart vocab)}

-- | Looks up a piece's token id (word-start spelling, as the specials use).
pieceId :: Vocab -> String -> Maybe Int
pieceId vocab = exactLookup (vocabStart vocab)

{- | Encodes text as a BERT input sequence: @[CLS]@, the text's word pieces,
@[SEP]@, capped at the given total token budget. The attention mask is all
ones (no padding is produced).
-}
encode :: Vocab -> Int -> String -> Encoded
encode vocab cap text =
    let tokens = concatMap splitPunctuation (words (normalise text))
        pieces = take (cap - 2) (concatMap (wordPieces vocab) tokens)
        ids = specialId vocab "[CLS]" : pieces ++ [specialId vocab "[SEP]"]
     in Encoded ids (map (const 1) ids)

{- | Splits a whitespace-delimited token at punctuation, every punctuation
character becoming its own token (the BERT basic-tokeniser rule).
-}
splitPunctuation :: String -> [String]
splitPunctuation = go []
  where
    go acc [] = flush acc []
    go acc (c : rest)
        | isPunct c = flush acc ([c] : go [] rest)
        | otherwise = go (c : acc) rest
    flush acc more = if null acc then more else reverse acc : more

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

{- | BERT uncased normalisation: lowercase and strip accents. Accent
stripping folds common Latin accented letters to their base letter (the
practical subset of Unicode NFD + drop-combining-marks for this corpus);
characters outside the table pass through unchanged.
-}
normalise :: String -> String
normalise = map (foldAccent . Char.toLower)

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

{- | A single word's piece ids: greedy longest-match-first against the
vocabulary, continuation pieces carrying the @##@ prefix. A word any part
of which cannot be matched becomes a single @[UNK]@ (the BERT rule: no
partial piece sequences).
-}
wordPieces :: Vocab -> String -> [Int]
wordPieces vocab word
    | length word > maxWordLength = [specialId vocab "[UNK]"]
    | otherwise = Maybe.fromMaybe [specialId vocab "[UNK]"] (go (vocabStart vocab) word)
  where
    go trie rest = do
        (tokenId, remaining) <- longestMatch trie rest
        if null remaining
            then Just [tokenId]
            else (tokenId :) <$> go (vocabContinuation vocab) remaining

-- | BERT's per-word character limit: longer words become @[UNK]@ unmatched.
maxWordLength :: Int
maxWordLength = 100

-- | A special token's id; the vocabulary must contain it.
specialId :: Vocab -> String -> Int
specialId vocab piece =
    case pieceId vocab piece of
        Just tokenId -> tokenId
        Nothing -> error ("Concordance.WordPiece: vocabulary lacks " ++ piece)
