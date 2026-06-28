module Verso.AttachmentSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Router as Router
import Test.Hspec
import qualified Verso.Attachment as Attachment

-- | The blob store used by the routing tests; content-addressed, under build/.
testRoot :: FilePath
testRoot = "build/attachment-spec"

testStore :: Attachment.AttachmentStore
testStore = Attachment.fileAttachmentStore testRoot

spec :: Spec
spec =
    describe "Verso.Attachment" $ do
        describe "contentHash" $ do
            it "is deterministic, distinguishes content, and is 32 lowercase hex digits" $ do
                Attachment.contentHash (BS.pack "hello") `shouldBe` Attachment.contentHash (BS.pack "hello")
                (Attachment.contentHash (BS.pack "hello") == Attachment.contentHash (BS.pack "world")) `shouldBe` False
                length (Attachment.contentHash (BS.pack "hello")) `shouldBe` 32
                all Char.isHexDigit (Attachment.contentHash (BS.pack "hello")) `shouldBe` True

        describe "upload" $ do
            it "given a file upload, stores the bytes and returns their reference url" $ do
                let body = "\137PNG\r\nfake image bytes"
                    hash = Attachment.contentHash (BS.pack body)
                response <- runAttachments (uploadRequest "logo.png") body
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodyText response `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/logo.png\"}"
                stored <- BS.readFile (testRoot ++ "/" ++ hash)
                stored `shouldBe` BS.pack body

            it "given the same bytes twice, dedups to the same url" $ do
                first <- runAttachments (uploadRequest "a.png") "same bytes"
                second <- runAttachments (uploadRequest "b.png") "same bytes"
                let hash = Attachment.contentHash (BS.pack "same bytes")
                bodyText first `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/a.png\"}"
                bodyText second `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/b.png\"}"

            it "given a disallowed type, rejects the upload with 415" $ do
                response <- runAttachments (uploadRequest "evil.html") "<script>alert(1)</script>"
                Http.statusCode (Http.responseStatus response) `shouldBe` 415

            it "given an unsafe filename, sanitises it in the returned url" $ do
                let hash = Attachment.contentHash (BS.pack "x")
                response <- runAttachments (uploadRequest "../etc/pa ss.png") "x"
                bodyText response `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/pa_ss.png\"}"

        describe "serve" $ do
            it "given an uploaded image, serves it inline with the right type and hardening headers" $ do
                let body = "\137PNG inline"
                    hash = Attachment.contentHash (BS.pack body)
                _ <- runAttachments (uploadRequest "logo.png") body
                response <- runAttachments (getRequest ["attachments", hash, "logo.png"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 200
                bodySize response `shouldBe` Just (BS.length (BS.pack body))
                headerValue "Content-Type" response `shouldBe` Just "image/png"
                headerValue "X-Content-Type-Options" response `shouldBe` Just "nosniff"
                headerValue "Content-Security-Policy" response `shouldBe` Just "default-src 'none'; sandbox"
                headerValue "Content-Disposition" response `shouldBe` Just "inline"

            it "given an uploaded text file, serves it as a download" $ do
                let hash = Attachment.contentHash (BS.pack "notes")
                _ <- runAttachments (uploadRequest "notes.txt") "notes"
                response <- runAttachments (getRequest ["attachments", hash, "notes.txt"]) ""
                headerValue "Content-Type" response `shouldBe` Just "text/plain"
                headerValue "Content-Disposition" response `shouldBe` Just "attachment; filename=\"notes.txt\""

            it "given an uploaded SVG, serves it as a download (never inline)" $ do
                let hash = Attachment.contentHash (BS.pack "<svg/>")
                _ <- runAttachments (uploadRequest "icon.svg") "<svg/>"
                response <- runAttachments (getRequest ["attachments", hash, "icon.svg"]) ""
                headerValue "Content-Type" response `shouldBe` Just "image/svg+xml"
                headerValue "Content-Disposition" response `shouldBe` Just "attachment; filename=\"icon.svg\""

            it "given a malformed hash, answers 404" $ do
                response <- runAttachments (getRequest ["attachments", "not-hex!!", "x.png"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 404

            it "given a well-formed but absent hash, answers 404" $ do
                response <- runAttachments (getRequest ["attachments", replicate 32 '0', "x.png"]) ""
                Http.statusCode (Http.responseStatus response) `shouldBe` 404

-- | Runs the attachment routes over a request head and body, returning the response.
runAttachments :: Http.RequestHead -> String -> IO Http.Response
runAttachments head body = do
    outcome <- Iteratee.strictEnumerator (BS.pack body) (Router.route (Attachment.attachmentRoutes testStore) head) >>= Iteratee.run
    case outcome of
        Right response -> return response
        Left err -> do
            ("stream failure: " ++ show err) `shouldBe` "no stream failure"
            return (Http.Response Http.okStatus [] (Http.StrictBody (BS.pack "")))

uploadRequest :: String -> Http.RequestHead
uploadRequest filename =
    Http.emptyRequestHead
        { Http.requestMethod = Http.POST
        , Http.requestPath = ["attachments"]
        , Http.requestHeaders = [(Http.normaliseHeaderName (BS.pack "x-attachment-filename"), BS.pack filename)]
        }

getRequest :: [String] -> Http.RequestHead
getRequest path =
    Http.emptyRequestHead{Http.requestMethod = Http.GET, Http.requestPath = path}

bodyText :: Http.Response -> String
bodyText response =
    case Http.responseBody response of
        Http.StrictBody body -> BS.unpack body
        _ -> "<non-strict body>"

bodySize :: Http.Response -> Maybe Int
bodySize response =
    case Http.responseBody response of
        Http.FileBody _ size -> Just size
        _ -> Nothing

headerValue :: String -> Http.Response -> Maybe String
headerValue name response =
    fmap BS.unpack (lookup (Http.normaliseHeaderName (BS.pack name)) (Http.responseHeaders response))
