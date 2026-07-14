module Verso.DocumentMetaSpec (spec) where

import qualified Control.Monad as Monad
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.DocumentMeta as DocumentMeta

-- | A meta directory under build/, cleaned per IO test by removing its two list files.
ioDir :: FilePath
ioDir = "build/document-meta-spec"

cleanFile :: FilePath -> IO ()
cleanFile f = do
    exists <- Directory.doesFileExist f
    Monad.when exists (Directory.removeFile f)

cleanMeta :: IO ()
cleanMeta = do
    cleanFile (ioDir ++ "/attachments.yaml")
    cleanFile (ioDir ++ "/images.yaml")

sampleAttachment :: DocumentMeta.AttachmentEntry
sampleAttachment =
    DocumentMeta.AttachmentEntry
        { DocumentMeta.attachmentName = "Request for Change Form.xlsx"
        , DocumentMeta.attachmentLocalPath = "assets/Request_for_Change_Form.xlsx"
        , DocumentMeta.attachmentExtension = "xlsx"
        }

spec :: Spec
spec =
    describe "Verso.DocumentMeta" $ do
        describe "metaDirectoryFor" $ do
            it "derives a nested page's meta directory" $
                DocumentMeta.metaDirectoryFor "root" "tenants/anzco/overview.md"
                    `shouldBe` Just "root/tenants/anzco/meta/overview.meta"

            it "derives a section index page's meta directory" $
                DocumentMeta.metaDirectoryFor "root" "engineering/index.md"
                    `shouldBe` Just "root/engineering/meta/index.meta"

            it "derives a top-level page's meta directory" $
                DocumentMeta.metaDirectoryFor "root" "index.md"
                    `shouldBe` Just "root/meta/index.meta"

            it "rejects an unsafe path" $
                DocumentMeta.metaDirectoryFor "root" "../secret.md" `shouldBe` Nothing

        describe "renderAttachmentEntry" $ do
            it "emits name, local_path, extension and external, omitting id and path" $
                DocumentMeta.renderAttachmentEntry sampleAttachment
                    `shouldBe` "- name: 'Request for Change Form.xlsx'\n\
                               \  local_path: assets/Request_for_Change_Form.xlsx\n\
                               \  extension: xlsx\n\
                               \  external: false\n"

            it "escapes a single quote in the name by doubling it" $
                attachmentNameLine (DocumentMeta.AttachmentEntry "O'Brien.pdf" "assets/O_Brien.pdf" "pdf")
                    `shouldBe` "- name: 'O''Brien.pdf'"

        describe "renderImageEntry" $ do
            it "emits local_path, single-quoted short_title and empty description" $
                DocumentMeta.renderImageEntry "assets/diagram.png" "My Diagram"
                    `shouldBe` "- local_path: assets/diagram.png\n\
                               \  short_title: 'My Diagram'\n\
                               \  description: ''\n"

        describe "addEntryDedup" $ do
            it "replaces an empty list with the new entry" $
                DocumentMeta.addEntryDedup "[]\n" (DocumentMeta.attachmentLocalPath sampleAttachment) (DocumentMeta.renderAttachmentEntry sampleAttachment)
                    `shouldBe` Just (DocumentMeta.renderAttachmentEntry sampleAttachment)

            it "appends to a populated list, preserving the existing entry verbatim" $ do
                let first = DocumentMeta.renderAttachmentEntry sampleAttachment
                    secondEntry = DocumentMeta.AttachmentEntry "Notes.txt" "assets/Notes.txt" "txt"
                    second = DocumentMeta.renderAttachmentEntry secondEntry
                DocumentMeta.addEntryDedup first (DocumentMeta.attachmentLocalPath secondEntry) second
                    `shouldBe` Just (first ++ second)

            it "returns Nothing when the local_path is already present (dedup)" $ do
                let existing = DocumentMeta.renderAttachmentEntry sampleAttachment
                DocumentMeta.addEntryDedup existing (DocumentMeta.attachmentLocalPath sampleAttachment) existing
                    `shouldBe` Nothing

        describe "setImageShortTitle" $ do
            it "replaces a matched entry's short_title and nothing else" $
                DocumentMeta.setImageShortTitle (DocumentMeta.renderImageEntry "assets/a.png" "Old") "assets/a.png" "New"
                    `shouldBe` Just (DocumentMeta.renderImageEntry "assets/a.png" "New")

            it "preserves other entries and a non-empty description" $ do
                let existing =
                        "- local_path: assets/a.png\n\
                        \  short_title: 'Old'\n\
                        \  description: 'Keep me'\n\
                        \- local_path: assets/b.png\n\
                        \  short_title: 'B'\n\
                        \  description: ''\n"
                    expected =
                        "- local_path: assets/a.png\n\
                        \  short_title: 'New'\n\
                        \  description: 'Keep me'\n\
                        \- local_path: assets/b.png\n\
                        \  short_title: 'B'\n\
                        \  description: ''\n"
                DocumentMeta.setImageShortTitle existing "assets/a.png" "New" `shouldBe` Just expected

            it "returns Nothing for an unmatched local_path" $
                DocumentMeta.setImageShortTitle (DocumentMeta.renderImageEntry "assets/a.png" "Old") "assets/zzz.png" "New"
                    `shouldBe` Nothing

            it "returns Nothing when the value is unchanged (no churn)" $
                DocumentMeta.setImageShortTitle (DocumentMeta.renderImageEntry "assets/a.png" "Old") "assets/a.png" "Old"
                    `shouldBe` Nothing

        describe "parseAttachments" $ do
            it "reads no entries from an empty list" $
                DocumentMeta.parseAttachments "[]\n" `shouldBe` []

            it "reads name and local_path from our own entries" $ do
                let a = DocumentMeta.AttachmentEntry "A.pdf" "assets/A.pdf" "pdf"
                    b = DocumentMeta.AttachmentEntry "B.pdf" "assets/B.pdf" "pdf"
                DocumentMeta.parseAttachments (DocumentMeta.renderAttachmentEntry a ++ DocumentMeta.renderAttachmentEntry b)
                    `shouldBe` [("A.pdf", "assets/A.pdf"), ("B.pdf", "assets/B.pdf")]

            it "reads name and local_path from a legacy CMS entry with id and path" $ do
                let legacy =
                        "- id: 194\n\
                        \  name: Request for Change Form.xlsx\n\
                        \  path: uploads/files/2023-03-Mar/yzQ9vMLmZYA293VV-xlsx\n\
                        \  local_path: assets/Request%20for%20Change%20Form.xlsx\n\
                        \  extension: xlsx\n\
                        \  external: false\n"
                DocumentMeta.parseAttachments legacy
                    `shouldBe` [("Request for Change Form.xlsx", "assets/Request%20for%20Change%20Form.xlsx")]

        describe "IO maintenance" $ do
            it "appendAttachment creates the file when absent and records the entry" $ do
                cleanMeta
                DocumentMeta.appendAttachment ioDir sampleAttachment
                contents <- FileSystem.readFileStrict (ioDir ++ "/attachments.yaml")
                contents `shouldBe` DocumentMeta.renderAttachmentEntry sampleAttachment

            it "appendAttachment is idempotent for an identical local_path" $ do
                cleanMeta
                DocumentMeta.appendAttachment ioDir sampleAttachment
                DocumentMeta.appendAttachment ioDir sampleAttachment
                contents <- FileSystem.readFileStrict (ioDir ++ "/attachments.yaml")
                contents `shouldBe` DocumentMeta.renderAttachmentEntry sampleAttachment

            it "appendImage then updateImageShortTitle records and then syncs short_title" $ do
                cleanMeta
                DocumentMeta.appendImage ioDir "assets/p.png" "p.png"
                DocumentMeta.updateImageShortTitle ioDir "assets/p.png" "A Caption"
                contents <- FileSystem.readFileStrict (ioDir ++ "/images.yaml")
                contents `shouldBe` DocumentMeta.renderImageEntry "assets/p.png" "A Caption"

            it "readAttachmentEntries reads back the recorded attachments" $ do
                cleanMeta
                DocumentMeta.appendAttachment ioDir sampleAttachment
                entries <- DocumentMeta.readAttachmentEntries ioDir
                entries `shouldBe` [(DocumentMeta.attachmentName sampleAttachment, DocumentMeta.attachmentLocalPath sampleAttachment)]

            it "readAttachmentEntries is empty when no file exists" $ do
                cleanMeta
                entries <- DocumentMeta.readAttachmentEntries ioDir
                entries `shouldBe` []

-- | The first line of a rendered attachment entry, for asserting name quoting in isolation.
attachmentNameLine :: DocumentMeta.AttachmentEntry -> String
attachmentNameLine = head . lines . DocumentMeta.renderAttachmentEntry
