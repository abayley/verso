module Verso.SearchChunksSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Test.Hspec
import qualified TestSupport.Scratch as Scratch
import qualified Verso.SearchChunks as SearchChunks

-- | A scratch directory under build/ for the streamed-chunking cases.
scratch :: FilePath
scratch = "build/search-chunks-spec"

-- | Writes the content to a scratch file and chunks it both ways: streamed from the file, and whole.
bothWays :: Int -> String -> BS.ByteString -> IO (Either String [SearchChunks.Chunk], [SearchChunks.Chunk])
bothWays cap title content = do
    Scratch.resetScratchDir scratch
    let path = scratch ++ "/page.md"
    BS.writeFile path content
    streamed <- SearchChunks.chunkFile cap title path
    whole <- SearchChunks.chunkPage cap title content
    pure (either (Left . show) Right streamed, whole)

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

        it "given a page with frontmatter, nested headings and a fence, when it is chunked from the file, then the chunks equal the whole-page chunking (RFC-0043)" $ do
            let content = BS.pack "---\nname: P\n---\nIntro.\n\n# Alpha\nA text.\n```\n# not heading\n\nstill fenced\n```\n\n## Beta\nB text.\n\n# Gamma\n\n# Delta\nD text.\n"
            (streamed, whole) <- bothWays 60 "P" content
            streamed `shouldBe` Right whole
            (length whole > 3) `shouldBe` True

        it "given a page longer than the read block with a heading and a paragraph straddling the block boundary, when it is chunked from the file, then the chunks equal the whole-page chunking (RFC-0043)" $ do
            let paragraph n = BS.pack ("paragraph " ++ show n ++ " " ++ replicate 40 'x')
                body = BS.intercalate (BS.pack "\n\n") (map paragraph [1 .. 3000 :: Int]) -- ~170KB, several 64KiB blocks
                content = BS.concat [BS.pack "# Top\n", body, BS.pack "\n\n## Deep heading near the end\ntail text\n"]
            (streamed, whole) <- bothWays 1500 "P" content
            streamed `shouldBe` Right whole
            (length whole > 50) `shouldBe` True

        it "given an opening frontmatter delimiter that is never closed, when chunked from the file, then it is content, as in the whole-page chunking (RFC-0043)" $ do
            let content = BS.pack "---\nname: never closed\n\n# Alpha\nA text.\n"
            (streamed, whole) <- bothWays 1500 "P" content
            streamed `shouldBe` Right whole
            map SearchChunks.chunkAnchor whole `shouldBe` ["", "Alpha"]

        it "given a missing file, when it is chunked from the file, then the failure is reported rather than an empty page (RFC-0043)" $ do
            Scratch.resetScratchDir scratch
            outcome <- SearchChunks.chunkFile 1500 "P" (scratch ++ "/absent.md")
            either (const True) (const False) outcome `shouldBe` True
