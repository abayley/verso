module MicroHttp.Utf8Spec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Utf8 as Utf8
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Utf8" $ do
        it "given text across the one, two, three and four byte ranges, when encoded, then the bytes are its UTF-8" $
            Utf8.encodeText "a\233\8212\1046\128512" `shouldBe` BS.pack "a\xc3\xa9\xe2\x80\x94\xd0\x96\xf0\x9f\x98\x80"
        it "given UTF-8 bytes, when decoded, then the characters come back" $
            Utf8.decodeBytes (BS.pack "a\xc3\xa9\xe2\x80\x94\xd0\x96\xf0\x9f\x98\x80") `shouldBe` "a\233\8212\1046\128512"
        it "given text, when encoded and decoded, then it round-trips" $ do
            let text = "Caf\233 \8212 \1046 \128512 plain ascii"
            Utf8.decodeBytes (Utf8.encodeText text) `shouldBe` text
        it "given the byte-per-Char forms, when used, then they agree with the byte forms" $ do
            Utf8.encodeUtf8 "\233\8212" `shouldBe` "\xc3\xa9\xe2\x80\x94"
            Utf8.decodeUtf8 "\xc3\xa9\xe2\x80\x94" `shouldBe` "\233\8212"
        it "given empty input, when encoded or decoded, then the result is empty" $ do
            Utf8.encodeText "" `shouldBe` BS.empty
            Utf8.decodeBytes BS.empty `shouldBe` ""
