module Verso.DocumentListingSpec (spec) where

import Test.Hspec
import qualified Verso.DocumentListing as DocumentListing

cardIndex :: String
cardIndex =
    unlines
        [ "# Section"
        , ""
        , "<div class=\"grid cards oracle-index\" markdown>"
        , ""
        , "- :material-a: [**Alpha**](./alpha/index.md) <span class=\"oracle-card-description\">One</span>"
        , "- :material-b: [**Beta**](./beta/index.md) <span class=\"oracle-card-description\">Two</span>"
        , ""
        , "</div>"
        ]

destCardIndex :: String
destCardIndex =
    unlines
        [ "# Section"
        , ""
        , "<div class=\"grid cards oracle-index\" markdown>"
        , ""
        , "- :material-a: [**Alpha**](./alpha/index.md) <span class=\"oracle-card-description\">One</span>"
        , ""
        , "</div>"
        ]

bulletIndex :: String
bulletIndex =
    unlines
        [ "# Folder"
        , ""
        , "- [First](./first.md)"
        , "- [Second](./second.md)"
        ]

spec :: Spec
spec =
    describe "Verso.DocumentListing" $ do
        describe "removeListingEntry" $ do
            it "given a card linking to the target, when the entry is removed, then the card goes and is returned" $ do
                (newText, removed) <- DocumentListing.removeListingEntry "" "beta/index.md" cardIndex
                removed
                    `shouldBe` Just "- :material-b: [**Beta**](./beta/index.md) <span class=\"oracle-card-description\">Two</span>"
                lines newText
                    `shouldBe` [ "# Section"
                               , ""
                               , "<div class=\"grid cards oracle-index\" markdown>"
                               , ""
                               , "- :material-a: [**Alpha**](./alpha/index.md) <span class=\"oracle-card-description\">One</span>"
                               , ""
                               , "</div>"
                               ]

            it "given a flat-page bullet linking to the target, when the entry is removed, then the bullet goes" $ do
                (newText, removed) <- DocumentListing.removeListingEntry "docs" "docs/second.md" bulletIndex
                removed `shouldBe` Just "- [Second](./second.md)"
                lines newText `shouldBe` ["# Folder", "", "- [First](./first.md)"]

            it "given no entry matching the target, when a removal is attempted, then the text is unchanged and nothing is returned" $ do
                DocumentListing.removeListingEntry "" "missing/index.md" cardIndex `shouldReturn` (cardIndex, Nothing)

        describe "addListingEntry" $ do
            it "given a grid block, when a card is added, then it is inserted before the closing div with its link repointed" $ do
                let entry = "- :material-b: [**Beta**](./beta/index.md) <span class=\"oracle-card-description\">Two</span>"
                result <- DocumentListing.addListingEntry "dest" "dest/beta/index.md" entry destCardIndex
                lines result
                    `shouldBe` [ "# Section"
                               , ""
                               , "<div class=\"grid cards oracle-index\" markdown>"
                               , ""
                               , "- :material-a: [**Alpha**](./alpha/index.md) <span class=\"oracle-card-description\">One</span>"
                               , "- :material-b: [**Beta**](./beta/index.md) <span class=\"oracle-card-description\">Two</span>"
                               , ""
                               , "</div>"
                               ]

            it "given a destination slug differing from the source, when a card is added, then its link is repointed" $ do
                let entry = "- :material-b: [**Beta**](./beta/index.md) <span class=\"oracle-card-description\">Two</span>"
                result <- DocumentListing.addListingEntry "dest" "dest/renamed/index.md" entry destCardIndex
                let expected = "- :material-b: [**Beta**](./renamed/index.md) <span class=\"oracle-card-description\">Two</span>"
                (expected `elem` lines result) `shouldBe` True

            it "given an existing bullet run, when a flat-page bullet is added, then it is appended to the run" $ do
                let entry = "- [Third](./third.md)"
                result <- DocumentListing.addListingEntry "docs" "docs/third.md" entry bulletIndex
                lines result
                    `shouldBe` [ "# Folder"
                               , ""
                               , "- [First](./first.md)"
                               , "- [Second](./second.md)"
                               , "- [Third](./third.md)"
                               ]
