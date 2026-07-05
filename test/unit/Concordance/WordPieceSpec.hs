module Concordance.WordPieceSpec (spec) where

import qualified Concordance.WordPiece as WordPiece
import qualified Data.ByteString.Char8 as BS
import Test.Hspec

-- | A tiny synthetic vocab: ids are line positions, mirroring vocab.txt.
tinyVocab :: WordPiece.Vocab
tinyVocab =
    WordPiece.mkVocab
        (BS.pack "[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\nworld\n,\n!\nun\n##believ\n##able\n##b\n##hello")

spec :: Spec
spec =
    describe "Concordance.WordPiece" $ do
        it "encodes the empty string as [CLS] [SEP] with an all-ones mask" $ do
            let enc = WordPiece.encode tinyVocab 512 ""
            WordPiece.encodedIds enc `shouldBe` [2, 3]
            WordPiece.encodedMask enc `shouldBe` [1, 1]

        it "encodes a single in-vocab word between the specials" $ do
            let enc = WordPiece.encode tinyVocab 512 "hello"
            WordPiece.encodedIds enc `shouldBe` [2, 4, 3]
            WordPiece.encodedMask enc `shouldBe` [1, 1, 1]

        it "lowercases and strips accents before lookup" $ do
            let enc = WordPiece.encode tinyVocab 512 "H\233LL\214"
            WordPiece.encodedIds enc `shouldBe` [2, 4, 3]

        it "splits punctuation into its own tokens" $ do
            let enc = WordPiece.encode tinyVocab 512 "hello, world!"
            WordPiece.encodedIds enc `shouldBe` [2, 4, 6, 5, 7, 3]

        it "splits an out-of-vocab word greedily into ## continuation pieces" $ do
            -- greedy longest match must pick ##believ over ##b
            let enc = WordPiece.encode tinyVocab 512 "unbelievable"
            WordPiece.encodedIds enc `shouldBe` [2, 8, 9, 10, 3]

        it "encodes a word with no matching pieces as [UNK]" $ do
            let enc = WordPiece.encode tinyVocab 512 "zzz"
            WordPiece.encodedIds enc `shouldBe` [2, 1, 3]

        it "encodes the whole word as [UNK] when matching fails mid-word" $ do
            -- un ##believ match, then 'zzz' has no piece: one [UNK], not partial pieces
            let enc = WordPiece.encode tinyVocab 512 "unbelievzzz"
            WordPiece.encodedIds enc `shouldBe` [2, 1, 3]

        it "encodes words longer than 100 characters as [UNK] without matching" $ do
            -- 20 hellos (100 chars) still match; 21 (105 chars) trip the length rule
            let hellos n = concat (replicate n "hello")
                atLimit = WordPiece.encode tinyVocab 512 (hellos 20)
                overLimit = WordPiece.encode tinyVocab 512 (hellos 21)
            WordPiece.encodedIds atLimit `shouldBe` [2, 4] ++ replicate 19 12 ++ [3]
            WordPiece.encodedIds overLimit `shouldBe` [2, 1, 3]

        it "matches vocab entries stored as multi-byte UTF-8" $ do
            -- an em dash piece is three UTF-8 bytes in vocab.txt but one Char in input
            let vocab =
                    WordPiece.mkVocab
                        (BS.pack "[PAD]\n[UNK]\n[CLS]\n[SEP]\n\226\128\148")
                enc = WordPiece.encode vocab 512 "\8212"
            WordPiece.encodedIds enc `shouldBe` [2, 4, 3]

        it "truncates to the cap, keeping [SEP] as the final token" $ do
            let enc = WordPiece.encode tinyVocab 4 "hello world hello"
            WordPiece.encodedIds enc `shouldBe` [2, 4, 5, 3]
            WordPiece.encodedMask enc `shouldBe` [1, 1, 1, 1]
