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
            it "removes the card whose link resolves to the target and returns it" $ do
                let (newText, removed) = DocumentListing.removeListingEntry "" "beta/index.md" cardIndex
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

            it "removes a flat-page bullet by its resolved target" $ do
                let (newText, removed) = DocumentListing.removeListingEntry "docs" "docs/second.md" bulletIndex
                removed `shouldBe` Just "- [Second](./second.md)"
                lines newText `shouldBe` ["# Folder", "", "- [First](./first.md)"]

            it "leaves the text unchanged and returns Nothing when no entry matches" $ do
                DocumentListing.removeListingEntry "" "missing/index.md" cardIndex `shouldBe` (cardIndex, Nothing)

        describe "addListingEntry" $ do
            it "inserts a card before the grid block's closing div, repointing its link to the destination" $ do
                let entry = "- :material-b: [**Beta**](./beta/index.md) <span class=\"oracle-card-description\">Two</span>"
                    result = DocumentListing.addListingEntry "dest" "dest/beta/index.md" entry destCardIndex
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

            it "repoints the link when the destination slug differs (a move with rename)" $ do
                let entry = "- :material-b: [**Beta**](./beta/index.md) <span class=\"oracle-card-description\">Two</span>"
                    result = DocumentListing.addListingEntry "dest" "dest/renamed/index.md" entry destCardIndex
                    expected = "- :material-b: [**Beta**](./renamed/index.md) <span class=\"oracle-card-description\">Two</span>"
                (expected `elem` lines result) `shouldBe` True

            it "appends a flat-page bullet to the existing bullet run" $ do
                let entry = "- [Third](./third.md)"
                    result = DocumentListing.addListingEntry "docs" "docs/third.md" entry bulletIndex
                lines result
                    `shouldBe` [ "# Folder"
                               , ""
                               , "- [First](./first.md)"
                               , "- [Second](./second.md)"
                               , "- [Third](./third.md)"
                               ]
