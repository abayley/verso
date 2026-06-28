module Verso.TrashSpec (spec) where

import Test.Hspec
import Verso.Trash (Manifest (..), TrashItem (..), parseManifest, renderManifest)

pageManifest :: Manifest
pageManifest =
    Manifest
        { manPath = "a/old.md"
        , manKind = "page"
        , manSeq = 5
        , manListing = Just "- [Old](./old.md)"
        , manItems =
            [ TrashItem "f0" False "a/old.md"
            , TrashItem "f1" True "a/meta/old.meta"
            , TrashItem "f2" False "a/assets/excl.png"
            ]
        }

sectionManifest :: Manifest
sectionManifest =
    Manifest
        { manPath = "a/sub"
        , manKind = "section"
        , manSeq = 9
        , manListing = Nothing
        , manItems = [TrashItem "payload" True "a/sub"]
        }

spec :: Spec
spec =
    describe "Verso.Trash" $ do
        it "round-trips a page manifest with multiple items" $
            parseManifest (renderManifest pageManifest) `shouldBe` Just pageManifest

        it "round-trips a section manifest" $
            parseManifest (renderManifest sectionManifest) `shouldBe` Just sectionManifest

        it "is Nothing when a required header is missing" $
            parseManifest "kind: page\nseq: 1\n" `shouldBe` Nothing
