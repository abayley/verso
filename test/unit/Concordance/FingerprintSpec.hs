module Concordance.FingerprintSpec (spec) where

import qualified Concordance.Fingerprint as Fingerprint
import qualified Data.ByteString.Char8 as BS
import Test.Hspec

spec :: Spec
spec =
    describe "Concordance.Fingerprint" $ do
        it "given the published FNV-1a 64 test vectors, when they are hashed, then the published digests are produced" $ do
            -- pins the algorithm so the C shim implementation must agree
            Fingerprint.contentFingerprint (BS.pack "")
                `shouldBe` "cbf29ce484222325"
            Fingerprint.contentFingerprint (BS.pack "a")
                `shouldBe` "af63dc4c8601ec8c"
            Fingerprint.contentFingerprint (BS.pack "foobar")
                `shouldBe` "85944171f73967e8"

        it "given equal content and then changed content, when each is fingerprinted, then the first matches and the second differs" $ do
            let fp = Fingerprint.contentFingerprint . BS.pack
            fp "same content" `shouldBe` fp "same content"
            (fp "same content" == fp "same content.") `shouldBe` False
