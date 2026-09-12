module Concordance.FingerprintSpec (spec) where

import qualified Concordance.Fingerprint as Fingerprint
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified System.Directory as Directory
import Test.Hspec

-- | A scratch directory under build/ for the streamed-fingerprint file tests.
scratch :: FilePath
scratch = "build/fingerprint-spec"

resetScratch :: IO ()
resetScratch = do
    exists <- Directory.doesDirectoryExist scratch
    Monad.when exists $ do
        names <- Directory.listDirectory scratch
        mapM_ (\n -> Directory.removeFile (scratch ++ "/" ++ n)) names
    Directory.createDirectoryIfMissing True scratch

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

        it "given a file read in blocks, when fingerprinted, then it equals the whole-bytes fingerprint at every size (RFC-0040)" $ do
            resetScratch
            let cases =
                    [ ("empty", BS.pack "")
                    , ("small", BS.pack "the quick brown fox")
                    , ("oneblock", BS.replicate 65536 'x')
                    , ("multiblock", BS.concat [BS.replicate 70000 'a', BS.pack "middle", BS.replicate 70000 'b'])
                    ]
            Monad.forM_ cases $ \(name, bytes) -> do
                let path = scratch ++ "/" ++ name
                BS.writeFile path bytes
                streamed <- Fingerprint.contentFingerprintFile path
                streamed `shouldBe` Right (Fingerprint.contentFingerprint bytes)

        it "given a missing file, when fingerprinted, then the failure is reported rather than a digest" $ do
            resetScratch
            outcome <- Fingerprint.contentFingerprintFile (scratch ++ "/absent")
            either (const True) (const False) outcome `shouldBe` True
