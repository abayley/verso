module Verso.SearchChunksSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Test.Hspec
import qualified Verso.SearchChunks as SearchChunks

-- | Chunks with a generous cap so size never splits in these tests.
chunk :: String -> String -> IO [SearchChunks.Chunk]
chunk title = SearchChunks.chunkPage 100000 title . BS.pack

-- | The chunk texts decoded back to Strings for comparison.
texts :: [SearchChunks.Chunk] -> [String]
texts = map (BS.unpack . SearchChunks.chunkText)

spec :: Spec
spec =
    describe "Verso.SearchChunks" $ do
        it "given a page with no headings, when it is chunked, then it yields one preamble chunk" $ do
            let content = "---\nname: My Page\n---\nFirst line.\n\nSecond line.\n"
            chunks <- chunk "My Page" content
            map SearchChunks.chunkAnchor chunks `shouldBe` [""]
            map SearchChunks.chunkSeq chunks `shouldBe` [0]
            texts chunks
                `shouldBe` ["My Page\nFirst line.\n\nSecond line."]

        it "given a page with nested headings, when it is chunked, then each section carries its title and ancestor context" $ do
            let content =
                    "Intro.\n\n# Alpha\nA text.\n\n## Beta\nB text.\n\n# Gamma\nG text.\n"
            chunks <- chunk "T" content
            map SearchChunks.chunkAnchor chunks
                `shouldBe` ["", "Alpha", "Beta", "Gamma"]
            map SearchChunks.chunkSeq chunks `shouldBe` [0, 1, 2, 3]
            texts chunks
                `shouldBe` [ "T\nIntro."
                           , "T\n# Alpha\nA text."
                           , "T > Alpha\n## Beta\nB text."
                           , "T\n# Gamma\nG text."
                           ]

        it "given a # inside a code fence, when the page is chunked, then it is not treated as a heading" $ do
            let content =
                    "# Alpha\ntext\n```bash\n# not a heading\necho hi\n```\nmore\n"
            chunks <- chunk "T" content
            map SearchChunks.chunkAnchor chunks `shouldBe` ["Alpha"]
            texts chunks
                `shouldBe` ["T\n# Alpha\ntext\n```bash\n# not a heading\necho hi\n```\nmore"]

        it "given an oversize section, when it is chunked, then it splits at paragraph boundaries with contiguous sequence numbers" $ do
            let content =
                    "# A\nfirst paragraph here\n\nsecond paragraph here\n\nthird paragraph here\n"
            chunks <- SearchChunks.chunkPage 50 "T" (BS.pack content)
            map SearchChunks.chunkAnchor chunks `shouldBe` ["A", "A"]
            map SearchChunks.chunkSeq chunks `shouldBe` [0, 1]
            texts chunks
                `shouldBe` [ "T\n# A\nfirst paragraph here\n\nsecond paragraph here"
                           , "T > A\nthird paragraph here"
                           ]

        it "given blank lines inside a code fence, when the page is chunked, then no split falls inside the fence" $ do
            let fence =
                    "```bash\nfirst command aaaaaaaaaaaaaaaaaaaa\n\nsecond command bbbbbbbbbbbbbbbbbbbb\n```"
                content = "# A\n" ++ fence ++ "\n\nafter paragraph text\n"
            chunks <- SearchChunks.chunkPage 50 "T" (BS.pack content)
            texts chunks
                `shouldBe` [ "T\n# A\n" ++ fence
                           , "T > A\nafter paragraph text"
                           ]
