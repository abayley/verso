module Verso.AttachmentSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http as Http
import Test.Hspec
import qualified Verso.Attachment as Attachment

spec :: Spec
spec =
    describe "Verso.Attachment" $ do
        describe "uploadFilename" $ do
            it "given a percent-encoded header, when read, then the decoded, sanitised last segment is returned" $
                Attachment.uploadFilename (withFilename "My%20Report%20(v2).pdf") `shouldBe` "My_Report__v2_.pdf"
            it "given a client path prefix, when read, then only the last segment is kept" $
                Attachment.uploadFilename (withFilename "..%2Fsecrets%2Fnotes.txt") `shouldBe` "notes.txt"
            it "given no filename header, when read, then the placeholder is returned" $
                Attachment.uploadFilename Http.emptyRequestHead `shouldBe` "file"
            it "given a name that sanitises to a special segment, when read, then the placeholder is returned" $
                Attachment.uploadFilename (withFilename "..") `shouldBe` "file"
        describe "originalUploadFilename" $ do
            it "given a percent-encoded header, when read, then the human-readable name keeps spaces and case" $
                Attachment.originalUploadFilename (withFilename "My%20Report%20(v2).pdf") `shouldBe` "My Report (v2).pdf"
            it "given no filename header, when read, then the placeholder is returned" $
                Attachment.originalUploadFilename Http.emptyRequestHead `shouldBe` "file"
        describe "extensionOf" $ do
            it "given a filename, when read, then the lower-cased extension is returned" $ do
                Attachment.extensionOf "Photo.JPG" `shouldBe` "jpg"
                Attachment.extensionOf "archive.tar.gz" `shouldBe` "gz"
            it "given no extension, when read, then the empty string is returned" $
                Attachment.extensionOf "README" `shouldBe` ""
        describe "type allow-list" $ do
            it "given the inline image types, when classified, then they are inline and allowed" $ do
                Attachment.inlineImageExtension "png" `shouldBe` True
                Attachment.allowedExtension "png" `shouldBe` True
            it "given SVG, when classified, then it is allowed but not inline (it can carry script)" $ do
                Attachment.allowedExtension "svg" `shouldBe` True
                Attachment.inlineImageExtension "svg" `shouldBe` False
            it "given an executable type, when classified, then it is not allowed" $
                Attachment.allowedExtension "exe" `shouldBe` False
        describe "percentDecode" $ do
            it "given %XX escapes, when decoded, then the bytes are restored and + is left alone" $
                Attachment.percentDecode "a%20b+c%2Fd" `shouldBe` "a b+c/d"
            it "given an invalid escape, when decoded, then it is kept literally" $
                Attachment.percentDecode "100%ZZ" `shouldBe` "100%ZZ"

-- | A request head carrying the (percent-encoded) upload filename header.
withFilename :: String -> Http.RequestHead
withFilename name =
    Http.emptyRequestHead
        { Http.requestHeaders = [(Http.normaliseHeaderName (BS.pack "X-Attachment-Filename"), BS.pack name)]
        }
