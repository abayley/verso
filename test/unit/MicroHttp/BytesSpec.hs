module MicroHttp.BytesSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Bytes as Bytes
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Bytes" $ do
        it "given a separator-terminated value, when splitting bytes, then it agrees with the library including the trailing empty piece" $
            Bytes.split '\n' (bs "a\nbb\n\nccc\n") `shouldBe` BS.split '\n' (bs "a\nbb\n\nccc\n")
        it "given empty bytes, when splitting, then there are no pieces" $
            Bytes.split '\n' (bs "") `shouldBe` []
        it "given bytes without the separator, when splitting, then the whole value is the one piece" $
            Bytes.split '\n' (bs "no newline here") `shouldBe` [bs "no newline here"]
        it "given only separators, when splitting, then every piece is empty, one more than the separators" $
            Bytes.split '\n' (bs "\n\n") `shouldBe` [bs "", bs "", bs ""]
        it "given a needle present mid-value, when testing infix, then it is found" $
            Bytes.isInfixOf (bs "](guides/") (bs "see [x](guides/failover.md) here") `shouldBe` True
        it "given an empty needle, when testing infix, then it is found, as the library does" $
            Bytes.isInfixOf (bs "") (bs "anything") `shouldBe` BS.isInfixOf (bs "") (bs "anything")
        it "given an absent needle sharing a first byte with the value, when testing infix, then it is not found" $
            Bytes.isInfixOf (bs "abd") (bs "abc abc abx") `shouldBe` False
        it "given a needle ending exactly at the end, when testing infix, then it is found" $
            Bytes.isInfixOf (bs ".md") (bs "guides/failover.md") `shouldBe` True
        it "given a needle longer than the value, when testing infix, then it is not found" $
            Bytes.isInfixOf (bs "longer than this") (bs "short") `shouldBe` False
        it "given bytes, when folding strictly, then it agrees with the library fold" $
            Bytes.foldl' (\acc c -> (acc * 31 + fromEnum c) `mod` 1000003) (7 :: Int) (bs "fnv-ish \xff bytes")
                `shouldBe` BS.foldl' (\acc c -> (acc * 31 + fromEnum c) `mod` 1000003) (7 :: Int) (bs "fnv-ish \xff bytes")
        it "given a corpus-sized value, when splitting, then every line is found and the count is exact" $
            length (Bytes.split '\n' megabyteLines) `shouldBe` 90 * 1024 + 1
        it "given a corpus-sized value, when folding strictly, then the fold completes with the exact byte total" $
            Bytes.foldl' (\acc _ -> acc + 1) (0 :: Int) megabyteLines `shouldBe` BS.length megabyteLines

bs :: String -> BS.ByteString
bs = BS.pack

{- | About 1.2MB of newline-terminated rows, the size of the persisted link index,
joined from packed chunks: packing a megabyte 'String' would itself be too deep a
list for the fixture to say anything about the code under test.
-}
megabyteLines :: BS.ByteString
megabyteLines = BS.concat (replicate 90 (BS.concat (replicate 1024 (bs "E\tpage/path.md\t\n"))))
