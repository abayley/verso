module Concordance.WordPieceFixtureSpec (spec) where

import qualified Concordance.Utf8 as Utf8
import qualified Concordance.WordPiece as WordPiece
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.FileSystem as FileSystem
import Test.Hspec

fixtureDir :: FilePath
fixtureDir = "test/integration/Concordance/fixtures"

{- | The reference probes: (text, expected ids), pairs of lines produced by
the genuine HuggingFace tokenizer (see wordpiece-fixtures.mjs).
-}
readProbes :: IO [(String, [Int])]
readProbes = do
    content <- FileSystem.readFileStrict (fixtureDir ++ "/tokenisations.txt")
    pure (pairs (lines content))
  where
    pairs (text : ids : rest) = (text, map read (words ids)) : pairs rest
    pairs _ = []

spec :: Spec
spec =
    describe "Concordance.WordPiece against HuggingFace reference fixtures" $
        it "reproduces the reference tokenisation of every probe" $ do
            vocab <- WordPiece.mkVocab <$> BS.readFile (fixtureDir ++ "/vocab.txt")
            probes <- readProbes
            length probes `shouldBe` 11
            Monad.forM_ probes $ \(text, expected) -> do
                let got = WordPiece.encodedIds (WordPiece.encode vocab 512 (BS.pack (Utf8.encodeUtf8 text)))
                (text, got) `shouldBe` (text, expected)
