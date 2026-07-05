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

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.Map.Strict as Map
import qualified Data.Maybe as Maybe

-- | A WordPiece vocabulary: piece text to token id.
newtype Vocab = Vocab (Map.Map String Int)

-- | An encoded sequence: token ids and the matching attention mask.
data Encoded = Encoded
    { encodedIds :: [Int]
    , encodedMask :: [Int]
    }
    deriving (Eq, Show)

{- | Builds a vocabulary from the raw bytes of a @vocab.txt@: one piece per
line, the token id being the zero-based line position.
-}
mkVocab :: BS.ByteString -> Vocab
mkVocab bytes =
    Vocab (Map.fromList (zip (map (decodeUtf8 . BS.unpack) (BS.split '\n' bytes)) [0 ..]))

{- | Decodes UTF-8 held as one 'Char' per byte (the @Char8@ view) into real
characters, so multi-byte vocabulary pieces compare equal to decoded input
text. Permissive: malformed sequences pass through byte-wise.
-}
decodeUtf8 :: String -> String
decodeUtf8 [] = []
decodeUtf8 (b0 : rest0)
    | c0 < 0x80 = b0 : decodeUtf8 rest0
    | c0 >= 0xC0 && c0 < 0xE0 = multi 1 (c0 - 0xC0)
    | c0 >= 0xE0 && c0 < 0xF0 = multi 2 (c0 - 0xE0)
    | c0 >= 0xF0 && c0 < 0xF8 = multi 3 (c0 - 0xF0)
    | otherwise = b0 : decodeUtf8 rest0
  where
    c0 = Char.ord b0
    multi n lead =
        let conts = take n rest0
         in if length conts == n && all isCont conts
                then
                    Char.chr (foldl (\acc c -> acc * 64 + (Char.ord c - 0x80)) lead conts)
                        : decodeUtf8 (drop n rest0)
                else b0 : decodeUtf8 rest0
    isCont c = Char.ord c >= 0x80 && Char.ord c < 0xC0

-- | Looks up a piece's token id.
pieceId :: Vocab -> String -> Maybe Int
pieceId (Vocab m) piece = Map.lookup piece m

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

-- | BERT's punctuation test: ASCII punctuation plus Unicode P categories.
isPunct :: Char -> Bool
isPunct c = Char.isPunctuation c || Char.isSymbol c

{- | BERT uncased normalisation: lowercase and strip accents. Accent
stripping folds common Latin accented letters to their base letter (the
practical subset of Unicode NFD + drop-combining-marks for this corpus);
characters outside the table pass through unchanged.
-}
normalise :: String -> String
normalise = map (foldAccent . Char.toLower)

-- | Folds one lowercased character's accent away, if it has one.
foldAccent :: Char -> Char
foldAccent c = Maybe.fromMaybe c (Map.lookup c accentTable)

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
    | otherwise = Maybe.fromMaybe [specialId vocab "[UNK]"] (go "" word)
  where
    go prefix rest = do
        (tokenId, remaining) <- longestPiece vocab prefix rest
        if null remaining
            then Just [tokenId]
            else (tokenId :) <$> go "##" remaining

{- | The longest vocabulary piece (with the given lookup prefix) that starts
the word, and the unconsumed remainder.
-}
longestPiece :: Vocab -> String -> String -> Maybe (Int, String)
longestPiece vocab prefix word = try (length word)
  where
    try 0 = Nothing
    try n =
        case pieceId vocab (prefix ++ take n word) of
            Just tokenId -> Just (tokenId, drop n word)
            Nothing -> try (n - 1)

-- | BERT's per-word character limit: longer words become @[UNK]@ unmatched.
maxWordLength :: Int
maxWordLength = 100

-- | A special token's id; the vocabulary must contain it.
specialId :: Vocab -> String -> Int
specialId vocab piece =
    case pieceId vocab piece of
        Just tokenId -> tokenId
        Nothing -> error ("Concordance.WordPiece: vocabulary lacks " ++ piece)
