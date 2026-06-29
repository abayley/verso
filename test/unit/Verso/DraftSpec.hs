module Verso.DraftSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Process as Process
import Test.Hspec
import qualified Verso.Draft as Draft

root :: FilePath
root = "build/draft-spec"

-- | Wipes the scratch draft root (rm -rf, since drafts nest under tree-relative paths).
fresh :: IO ()
fresh = Monad.void (Process.runProcess "rm" ["-rf", root] Nothing Nothing)

spec :: Spec
spec =
    describe "Verso.Draft" $ do
        it "stages a draft and reads it back" $ do
            fresh
            Draft.writeDraft root "sec/page.md" (BS.pack "draft body")
            has <- Draft.hasDraft root "sec/page.md"
            has `shouldBe` True
            got <- Draft.readDraft root "sec/page.md"
            got `shouldBe` Just (BS.pack "draft body")

        it "reports no draft when none is staged" $ do
            fresh
            has <- Draft.hasDraft root "missing.md"
            has `shouldBe` False
            got <- Draft.readDraft root "missing.md"
            got `shouldBe` Nothing

        it "deletes a staged draft" $ do
            fresh
            Draft.writeDraft root "p.md" (BS.pack "x")
            Draft.deleteDraft root "p.md"
            has <- Draft.hasDraft root "p.md"
            has `shouldBe` False

        it "maps a tree path to a draft path under the root" $
            Draft.draftFsPath "data/drafts" "a/b.md" `shouldBe` "data/drafts/a/b.md"
