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
        it "given a draft, when it is staged, then it reads back" $ do
            fresh
            Draft.writeDraft root "sec/page.md" (BS.pack "draft body")
            has <- Draft.hasDraft root "sec/page.md"
            has `shouldBe` True
            BS.readFile (root ++ "/sec/page.md") `shouldReturn` BS.pack "draft body"

        it "given no staged draft, when one is read, then none is reported" $ do
            fresh
            has <- Draft.hasDraft root "missing.md"
            has `shouldBe` False

        it "given a staged draft, when it is deleted, then it is gone" $ do
            fresh
            Draft.writeDraft root "p.md" (BS.pack "x")
            Draft.deleteDraft root "p.md"
            has <- Draft.hasDraft root "p.md"
            has `shouldBe` False

        it "given a tree path, when it is mapped, then it lands under the draft root" $
            Draft.draftFsPath "data/drafts" "a/b.md" `shouldBe` "data/drafts/a/b.md"
