module Verso.LinkRewriteSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.DocumentLinks as DocumentLinks
import qualified Verso.LinkRewrite as LinkRewrite

-- | A scratch file under build/, rewritten in place by each test.
page :: FilePath
page = "build/link-rewrite-spec.md"

-- | Repoints every in-tree .md target to NEW, leaving assets and externals alone.
repointPages :: DocumentLinks.Link -> Maybe String
repointPages link
    | ".md" `isSuffix` DocumentLinks.linkTarget link = Just "NEW"
    | otherwise = Nothing
  where
    isSuffix s t = reverse s == take (length s) (reverse t)

fresh :: BS.ByteString -> IO ()
fresh content = do
    Monad.forM_ [page, page ++ ".tmp"] $ \p -> do
        isDir <- Directory.doesDirectoryExist p
        Monad.when isDir (Monad.void (FileSystem.removeEmptyDir p))
        exists <- Directory.doesFileExist p
        Monad.when exists (Directory.removeFile p)
    BS.writeFile page content

spec :: Spec
spec =
    describe "Verso.LinkRewrite" $ do
        it "given links straddling every chunk boundary, when a page is rewritten as a stream, then the result equals the whole-body rewrite" $ do
            fresh fixture
            links <- DocumentLinks.pageLinks fixture
            let edits = [(DocumentLinks.linkStart l, DocumentLinks.linkEnd l, r) | l <- links, Just r <- [repointPages l]]
                expected = DocumentLinks.rewriteLinks fixture edits
            outcome <- LinkRewrite.rewriteFileLinksChunked 7 repointPages page
            outcome `shouldBe` Right True
            BS.readFile page `shouldReturn` expected
            (expected /= fixture) `shouldBe` True
            Directory.doesFileExist (page ++ ".tmp") `shouldReturn` False
        it "given a page with nothing to rewrite, when it is rewritten, then it is reported unchanged and left as it was" $ do
            fresh (BS.pack "no links here\n![i](assets/i.png)\n")
            outcome <- LinkRewrite.rewriteFileLinksChunked 7 repointPages page
            outcome `shouldBe` Right False
            BS.readFile page `shouldReturn` BS.pack "no links here\n![i](assets/i.png)\n"
            Directory.doesFileExist (page ++ ".tmp") `shouldReturn` False
        it "given the temporary file cannot be written, when a page is rewritten, then it fails and the original is intact" $ do
            fresh fixture
            Directory.createDirectoryIfMissing True (page ++ ".tmp")
            outcome <- LinkRewrite.rewriteFileLinksChunked 7 repointPages page
            either (const True) (const False) outcome `shouldBe` True
            BS.readFile page `shouldReturn` fixture
            Monad.void (FileSystem.removeEmptyDir (page ++ ".tmp"))
        it "given a missing page, when it is rewritten, then it fails" $ do
            fresh fixture
            Directory.removeFile page
            outcome <- LinkRewrite.rewriteFileLinksChunked 7 repointPages page
            either (const True) (const False) outcome `shouldBe` True

-- | Links of varying length so 7-byte chunks cut targets, titles, a fence, and the final unterminated line.
fixture :: BS.ByteString
fixture =
    BS.pack
        "# T\n\
        \[a](./a.md) and [bb](../up/bb.md \"title\") then ![i](assets/pic.png)\r\n\
        \```\n\
        \[fenced](./ignored.md)\n\
        \```\n\
        \[c](<./c d.md>#frag) [e](https://x.test/e.md)\n\
        \[last](./last.md)"
