module Verso.TrashSpec (spec) where

import Test.Hspec
import qualified Verso.Trash as Trash

pageManifest :: Trash.Manifest
pageManifest =
    Trash.Manifest
        { Trash.manPath = "a/old.md"
        , Trash.manKind = "page"
        , Trash.manSeq = 5
        , Trash.manListing = Just "- [Old](./old.md)"
        , Trash.manItems =
            [ Trash.TrashItem "f0" False "a/old.md"
            , Trash.TrashItem "f1" True "a/meta/old.meta"
            , Trash.TrashItem "f2" False "a/assets/excl.png"
            ]
        }

sectionManifest :: Trash.Manifest
sectionManifest =
    Trash.Manifest
        { Trash.manPath = "a/sub"
        , Trash.manKind = "section"
        , Trash.manSeq = 9
        , Trash.manListing = Nothing
        , Trash.manItems = [Trash.TrashItem "payload" True "a/sub"]
        }

spec :: Spec
spec =
    describe "Verso.Trash" $ do
        it "given a page manifest with several items, when it is rendered and parsed back, then the original is returned" $
            Trash.parseManifest (Trash.renderManifest pageManifest) `shouldBe` Just pageManifest

        it "given a section manifest, when it is rendered and parsed back, then the original is returned" $
            Trash.parseManifest (Trash.renderManifest sectionManifest) `shouldBe` Just sectionManifest

        it "given a manifest missing a required header, when it is parsed, then nothing is returned" $
            Trash.parseManifest "kind: page\nseq: 1\n" `shouldBe` Nothing
