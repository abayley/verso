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
            it "given a nested page, when its meta directory is derived, then it sits beside the page" $
                DocumentMeta.metaDirectoryFor "root" "tenants/anzco/overview.md"
                    `shouldBe` Just "root/tenants/anzco/meta/overview.meta"

            it "given a section index page, when its meta directory is derived, then it sits beside the section" $
                DocumentMeta.metaDirectoryFor "root" "engineering/index.md"
                    `shouldBe` Just "root/engineering/meta/index.meta"

            it "given a top-level page, when its meta directory is derived, then it sits at the root" $
                DocumentMeta.metaDirectoryFor "root" "index.md"
                    `shouldBe` Just "root/meta/index.meta"

            it "given a path escaping the root, when its meta directory is derived, then nothing is returned" $
                DocumentMeta.metaDirectoryFor "root" "../secret.md" `shouldBe` Nothing

        describe "renderAttachmentEntry" $ do
            it "given an attachment, when rendered, then name, local_path, extension and external are emitted and id and path omitted" $
                DocumentMeta.renderAttachmentEntry sampleAttachment
                    `shouldBe` "- name: 'Request for Change Form.xlsx'\n\
                               \  local_path: assets/Request_for_Change_Form.xlsx\n\
                               \  extension: xlsx\n\
                               \  external: false\n"

            it "given a name containing a single quote, when rendered, then the quote is doubled" $
                attachmentNameLine (DocumentMeta.AttachmentEntry "O'Brien.pdf" "assets/O_Brien.pdf" "pdf")
                    `shouldBe` "- name: 'O''Brien.pdf'"

        describe "renderImageEntry" $ do
            it "given an image and a title, when rendered, then local_path, a quoted short_title and an empty description are emitted" $
                DocumentMeta.renderImageEntry "assets/diagram.png" "My Diagram"
                    `shouldBe` "- local_path: assets/diagram.png\n\
                               \  short_title: 'My Diagram'\n\
                               \  description: ''\n"

        describe "addEntryDedup" $ do
            it "given an empty list, when an entry is added, then the list holds only that entry" $
                DocumentMeta.addEntryDedup "[]\n" (DocumentMeta.attachmentLocalPath sampleAttachment) (DocumentMeta.renderAttachmentEntry sampleAttachment)
                    `shouldBe` Just (DocumentMeta.renderAttachmentEntry sampleAttachment)

            it "given a populated list, when an entry is added, then it is appended and the existing entry is preserved verbatim" $ do
                let first = DocumentMeta.renderAttachmentEntry sampleAttachment
                    secondEntry = DocumentMeta.AttachmentEntry "Notes.txt" "assets/Notes.txt" "txt"
                    second = DocumentMeta.renderAttachmentEntry secondEntry
                DocumentMeta.addEntryDedup first (DocumentMeta.attachmentLocalPath secondEntry) second
                    `shouldBe` Just (first ++ second)

            it "given an entry whose local_path is already present, when it is added, then nothing is returned" $ do
                let existing = DocumentMeta.renderAttachmentEntry sampleAttachment
                DocumentMeta.addEntryDedup existing (DocumentMeta.attachmentLocalPath sampleAttachment) existing
                    `shouldBe` Nothing

        describe "setImageShortTitle" $ do
            it "given a matching entry, when its short title is set, then only the short_title changes" $
                DocumentMeta.setImageShortTitle (DocumentMeta.renderImageEntry "assets/a.png" "Old") "assets/a.png" "New"
                    `shouldBe` Just (DocumentMeta.renderImageEntry "assets/a.png" "New")

            it "given other entries and a non-empty description, when a short title is set, then both are preserved" $ do
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

            it "given a local_path that matches nothing, when a short title is set, then nothing is returned" $
                DocumentMeta.setImageShortTitle (DocumentMeta.renderImageEntry "assets/a.png" "Old") "assets/zzz.png" "New"
                    `shouldBe` Nothing

            it "given a short title equal to the stored one, when it is set, then nothing is returned" $
                DocumentMeta.setImageShortTitle (DocumentMeta.renderImageEntry "assets/a.png" "Old") "assets/a.png" "Old"
                    `shouldBe` Nothing

        describe "parseAttachments" $ do
            it "given an empty list, when parsed, then no entries are returned" $
                DocumentMeta.parseAttachments "[]\n" `shouldBe` []

            it "given entries this module wrote, when parsed, then their name and local_path are read" $ do
                let a = DocumentMeta.AttachmentEntry "A.pdf" "assets/A.pdf" "pdf"
                    b = DocumentMeta.AttachmentEntry "B.pdf" "assets/B.pdf" "pdf"
                DocumentMeta.parseAttachments (DocumentMeta.renderAttachmentEntry a ++ DocumentMeta.renderAttachmentEntry b)
                    `shouldBe` [("A.pdf", "assets/A.pdf"), ("B.pdf", "assets/B.pdf")]

            it "given a legacy CMS entry carrying id and path, when parsed, then its name and local_path are read" $ do
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
            it "given no meta file, when an attachment is appended, then the file is created holding the entry" $ do
                cleanMeta
                DocumentMeta.appendAttachment ioDir sampleAttachment
                contents <- FileSystem.readFileStrict (ioDir ++ "/attachments.yaml")
                contents `shouldBe` DocumentMeta.renderAttachmentEntry sampleAttachment

            it "given an attachment already recorded, when the same local_path is appended, then nothing is duplicated" $ do
                cleanMeta
                DocumentMeta.appendAttachment ioDir sampleAttachment
                DocumentMeta.appendAttachment ioDir sampleAttachment
                contents <- FileSystem.readFileStrict (ioDir ++ "/attachments.yaml")
                contents `shouldBe` DocumentMeta.renderAttachmentEntry sampleAttachment

            it "given a recorded image, when its short title is updated, then the stored short_title follows" $ do
                cleanMeta
                DocumentMeta.appendImage ioDir "assets/p.png" "p.png"
                DocumentMeta.updateImageShortTitle ioDir "assets/p.png" "A Caption"
                contents <- FileSystem.readFileStrict (ioDir ++ "/images.yaml")
                contents `shouldBe` DocumentMeta.renderImageEntry "assets/p.png" "A Caption"

            it "given recorded attachments, when they are read back, then the same entries are returned" $ do
                cleanMeta
                DocumentMeta.appendAttachment ioDir sampleAttachment
                entries <- DocumentMeta.readAttachmentEntries ioDir
                entries `shouldBe` [(DocumentMeta.attachmentName sampleAttachment, DocumentMeta.attachmentLocalPath sampleAttachment)]

            it "given no meta file, when attachments are read back, then none are returned" $ do
                cleanMeta
                entries <- DocumentMeta.readAttachmentEntries ioDir
                entries `shouldBe` []
            it "given an attachment whose original name holds characters outside Latin-1, when it is appended and read back, then the name round-trips (RFC-0043)" $ do
                cleanMeta
                let entry = DocumentMeta.AttachmentEntry "Übersicht \8212 \1046.pdf" "assets/Ubersicht.pdf" "pdf"
                DocumentMeta.appendAttachment ioDir entry
                DocumentMeta.readAttachmentEntries ioDir `shouldReturn` [("Übersicht \8212 \1046.pdf", "assets/Ubersicht.pdf")]

-- | The first line of a rendered attachment entry, for asserting name quoting in isolation.
attachmentNameLine :: DocumentMeta.AttachmentEntry -> String
attachmentNameLine = head . lines . DocumentMeta.renderAttachmentEntry
