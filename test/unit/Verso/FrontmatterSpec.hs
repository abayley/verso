module Verso.FrontmatterSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Iteratee as Iteratee
import Test.Hspec
import qualified Verso.Frontmatter as Frontmatter

spec :: Spec
spec =
    describe "Verso.Frontmatter" $ do
        describe "title" $ do
            it "given frontmatter with a name, when read, then the title is returned (quotes stripped)" $ do
                Frontmatter.title "---\nname: Engineering\nmeta: x\n---\n\n# Body" `shouldBe` Just "Engineering"
                Frontmatter.title "---\nname: \"A: title\"\n---" `shouldBe` Just "A: title"
                Frontmatter.title "---\r\nname: 'It''s'\r\n---\r\n" `shouldBe` Just "It's"
            it "given no frontmatter or no name, when read, then Nothing is returned" $ do
                Frontmatter.title "# Just a body\n" `shouldBe` Nothing
                Frontmatter.title "---\nmeta: x\n---" `shouldBe` Nothing
            it "given a name only after the closing delimiter, when read, then it is not a title" $
                Frontmatter.title "---\nmeta: x\n---\nname: Body\n" `shouldBe` Nothing

        describe "leadingBlock" $ do
            it "given content opening with a body line, when classified, then there is no frontmatter" $
                Frontmatter.leadingBlock (BS.pack "# Title\n---\n") `shouldBe` Frontmatter.NoFrontmatter
            it "given an opening delimiter with no closing one yet, when classified, then the block is unclosed" $
                Frontmatter.leadingBlock (BS.pack "---\nname: x\n") `shouldBe` Frontmatter.Unclosed
            it "given a closed block, when classified, then both delimiter lines are the block and the body is excluded" $
                Frontmatter.leadingBlock (BS.pack "---\r\nname: x\r\n---\r\n# Body\n")
                    `shouldBe` Frontmatter.Frontmatter (BS.pack "---\r\nname: x\r\n---\r")
            it "given a delimiter with trailing spaces, when classified, then it still delimits" $
                Frontmatter.leadingBlock (BS.pack "---  \nname: x\n---\t\nbody")
                    `shouldBe` Frontmatter.Frontmatter (BS.pack "---  \nname: x\n---\t")

        describe "blockI" $ do
            it "given a first chunk holding the whole block, when fed, then it completes without asking for the body" $
                feedAll [BS.pack "---\nname: x\n---\nbody starts"] `shouldBe` Just (Just (BS.pack "---\nname: x\n---"))
            it "given a block split across two chunks, when fed, then the second chunk completes it" $ do
                feedAll [BS.pack "---\nname: x\n--"] `shouldBe` Nothing
                feedAll [BS.pack "---\nname: x\n--", BS.pack "-\nbody"] `shouldBe` Just (Just (BS.pack "---\nname: x\n---"))
            it "given a first chunk opening with the body, when fed, then it completes at once with no block" $
                feedAll [BS.pack "# Heading\n---\n"] `shouldBe` Just (Just BS.empty)
            it "given an unclosed block past the size cap, when fed, then it gives up with no block" $
                feedAll [BS.pack "---\n", BS.replicate (Frontmatter.blockCapBytes + 1) 'x'] `shouldBe` Just (Just BS.empty)
            it "given end of stream inside an unclosed block, when fed, then there is no block" $
                case Frontmatter.blockI of
                    Iteratee.NeedInput k ->
                        Iteratee.run (k (Iteratee.Chunk (BS.pack "---\nname: x\n")))
                            `shouldReturn` (Right BS.empty :: Either () BS.ByteString)
                    _ -> False `shouldBe` True

-- | Feeds chunks to 'blockI' in order; Just once it completes (with its result), Nothing if it still wants input.
feedAll :: [BS.ByteString] -> Maybe (Maybe BS.ByteString)
feedAll = go Frontmatter.blockI
  where
    go it chunks = case it of
        Iteratee.Done block _ -> Just (Just block)
        Iteratee.IterFailed () _ -> Just Nothing
        Iteratee.IterM _ -> Nothing
        Iteratee.NeedInput k -> case chunks of
            [] -> Nothing
            (c : rest) -> go (k (Iteratee.Chunk c)) rest
