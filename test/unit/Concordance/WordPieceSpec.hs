module Concordance.WordPieceSpec (spec) where

import qualified Concordance.Utf8 as Utf8
import qualified Concordance.WordPiece as WordPiece
import qualified Data.ByteString.Char8 as BS
import Test.Hspec

-- | A tiny synthetic vocab: ids are line positions, mirroring vocab.txt.
tinyVocab :: WordPiece.Vocab
tinyVocab =
    WordPiece.mkVocab
        (BS.pack "[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\nworld\n,\n!\nun\n##believ\n##able\n##b\n##hello")

-- | Test input as UTF-8 bytes (encode's input type).
utf8 :: String -> BS.ByteString
utf8 = BS.pack . Utf8.encodeUtf8

spec :: Spec
spec =
    describe "Concordance.WordPiece" $ do
        it "given the empty string, when encoded, then it is [CLS] [SEP] with an all-ones mask" $ do
            let enc = WordPiece.encode tinyVocab 512 (utf8 "")
            WordPiece.encodedIds enc `shouldBe` [2, 3]
            WordPiece.encodedMask enc `shouldBe` [1, 1]

        it "given a single in-vocab word, when encoded, then it sits between the special tokens" $ do
            let enc = WordPiece.encode tinyVocab 512 (utf8 "hello")
            WordPiece.encodedIds enc `shouldBe` [2, 4, 3]
            WordPiece.encodedMask enc `shouldBe` [1, 1, 1]

        it "given uppercase accented text, when encoded, then it is lowercased and stripped before lookup" $ do
            let enc = WordPiece.encode tinyVocab 512 (utf8 "H\233LL\214")
            WordPiece.encodedIds enc `shouldBe` [2, 4, 3]

        it "given text containing punctuation, when encoded, then the punctuation becomes its own tokens" $ do
            let enc = WordPiece.encode tinyVocab 512 (utf8 "hello, world!")
            WordPiece.encodedIds enc `shouldBe` [2, 4, 6, 5, 7, 3]

        it "given an out-of-vocab word, when encoded, then it splits greedily into ## continuation pieces" $ do
            -- greedy longest match must pick ##believ over ##b
            let enc = WordPiece.encode tinyVocab 512 (utf8 "unbelievable")
            WordPiece.encodedIds enc `shouldBe` [2, 8, 9, 10, 3]

        it "given a word with no matching pieces, when encoded, then it becomes [UNK]" $ do
            let enc = WordPiece.encode tinyVocab 512 (utf8 "zzz")
            WordPiece.encodedIds enc `shouldBe` [2, 1, 3]

        it "given a word whose match fails part way through, when encoded, then the whole word becomes [UNK]" $ do
            -- un ##believ match, then 'zzz' has no piece: one [UNK], not partial pieces
            let enc = WordPiece.encode tinyVocab 512 (utf8 "unbelievzzz")
            WordPiece.encodedIds enc `shouldBe` [2, 1, 3]

        it "given a word longer than 100 characters, when encoded, then it becomes [UNK] without matching" $ do
            -- 20 hellos (100 chars) still match; 21 (105 chars) trip the length rule
            let hellos n = concat (replicate n "hello")
                atLimit = WordPiece.encode tinyVocab 512 (utf8 (hellos 20))
                overLimit = WordPiece.encode tinyVocab 512 (utf8 (hellos 21))
            WordPiece.encodedIds atLimit `shouldBe` [2, 4] ++ replicate 19 12 ++ [3]
            WordPiece.encodedIds overLimit `shouldBe` [2, 1, 3]

        it "given a vocab entry stored as multi-byte UTF-8, when encoded, then it is matched" $ do
            -- an em dash piece is three UTF-8 bytes in vocab.txt but one Char in input
            let vocab =
                    WordPiece.mkVocab
                        (BS.pack "[PAD]\n[UNK]\n[CLS]\n[SEP]\n\226\128\148")
                enc = WordPiece.encode vocab 512 (utf8 "\8212")
            WordPiece.encodedIds enc `shouldBe` [2, 4, 3]

        it "given more tokens than the cap allows, when encoded, then the output is truncated and still ends with [SEP]" $ do
            let enc = WordPiece.encode tinyVocab 4 (utf8 "hello world hello")
            WordPiece.encodedIds enc `shouldBe` [2, 4, 5, 3]
            WordPiece.encodedMask enc `shouldBe` [1, 1, 1, 1]
