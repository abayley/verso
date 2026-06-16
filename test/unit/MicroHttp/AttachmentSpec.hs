module MicroHttp.AttachmentSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (isHexDigit)
import MicroHttp.Attachment (AttachmentStore, attachmentRoutes, contentHash, fileAttachmentStore)
import MicroHttp.Http
import MicroHttp.Iteratee (run, strictEnumerator)
import qualified MicroHttp.Router as Router
import Test.Hspec

-- | The blob store used by the routing tests; content-addressed, under build/.
testRoot :: FilePath
testRoot = "build/attachment-spec"

testStore :: AttachmentStore
testStore = fileAttachmentStore testRoot

spec :: Spec
spec =
    describe "MicroHttp.Attachment" $ do
        describe "contentHash" $ do
            it "is deterministic, distinguishes content, and is 32 lowercase hex digits" $ do
                contentHash (BS.pack "hello") `shouldBe` contentHash (BS.pack "hello")
                (contentHash (BS.pack "hello") == contentHash (BS.pack "world")) `shouldBe` False
                length (contentHash (BS.pack "hello")) `shouldBe` 32
                all isHexDigit (contentHash (BS.pack "hello")) `shouldBe` True

        describe "upload" $ do
            it "given a file upload, stores the bytes and returns their reference url" $ do
                let body = "\137PNG\r\nfake image bytes"
                    hash = contentHash (BS.pack body)
                response <- runAttachments (uploadRequest "logo.png") body
                statusCode (responseStatus response) `shouldBe` 200
                bodyText response `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/logo.png\"}"
                stored <- BS.readFile (testRoot ++ "/" ++ hash)
                stored `shouldBe` BS.pack body

            it "given the same bytes twice, dedups to the same url" $ do
                first <- runAttachments (uploadRequest "a.png") "same bytes"
                second <- runAttachments (uploadRequest "b.png") "same bytes"
                let hash = contentHash (BS.pack "same bytes")
                bodyText first `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/a.png\"}"
                bodyText second `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/b.png\"}"

            it "given a disallowed type, rejects the upload with 415" $ do
                response <- runAttachments (uploadRequest "evil.html") "<script>alert(1)</script>"
                statusCode (responseStatus response) `shouldBe` 415

            it "given an unsafe filename, sanitises it in the returned url" $ do
                let hash = contentHash (BS.pack "x")
                response <- runAttachments (uploadRequest "../etc/pa ss.png") "x"
                bodyText response `shouldBe` "{\"url\":\"/attachments/" ++ hash ++ "/pa_ss.png\"}"

        describe "serve" $ do
            it "given an uploaded image, serves it inline with the right type and hardening headers" $ do
                let body = "\137PNG inline"
                    hash = contentHash (BS.pack body)
                _ <- runAttachments (uploadRequest "logo.png") body
                response <- runAttachments (getRequest ["attachments", hash, "logo.png"]) ""
                statusCode (responseStatus response) `shouldBe` 200
                bodySize response `shouldBe` Just (BS.length (BS.pack body))
                headerValue "Content-Type" response `shouldBe` Just "image/png"
                headerValue "X-Content-Type-Options" response `shouldBe` Just "nosniff"
                headerValue "Content-Security-Policy" response `shouldBe` Just "default-src 'none'; sandbox"
                headerValue "Content-Disposition" response `shouldBe` Just "inline"

            it "given an uploaded text file, serves it as a download" $ do
                let hash = contentHash (BS.pack "notes")
                _ <- runAttachments (uploadRequest "notes.txt") "notes"
                response <- runAttachments (getRequest ["attachments", hash, "notes.txt"]) ""
                headerValue "Content-Type" response `shouldBe` Just "text/plain"
                headerValue "Content-Disposition" response `shouldBe` Just "attachment; filename=\"notes.txt\""

            it "given an uploaded SVG, serves it as a download (never inline)" $ do
                let hash = contentHash (BS.pack "<svg/>")
                _ <- runAttachments (uploadRequest "icon.svg") "<svg/>"
                response <- runAttachments (getRequest ["attachments", hash, "icon.svg"]) ""
                headerValue "Content-Type" response `shouldBe` Just "image/svg+xml"
                headerValue "Content-Disposition" response `shouldBe` Just "attachment; filename=\"icon.svg\""

            it "given a malformed hash, answers 404" $ do
                response <- runAttachments (getRequest ["attachments", "not-hex!!", "x.png"]) ""
                statusCode (responseStatus response) `shouldBe` 404

            it "given a well-formed but absent hash, answers 404" $ do
                response <- runAttachments (getRequest ["attachments", replicate 32 '0', "x.png"]) ""
                statusCode (responseStatus response) `shouldBe` 404

-- | Runs the attachment routes over a request head and body, returning the response.
runAttachments :: RequestHead -> String -> IO Response
runAttachments head body = do
    outcome <- strictEnumerator (BS.pack body) (Router.route (attachmentRoutes testStore) head) >>= run
    case outcome of
        Right response -> return response
        Left err -> do
            ("stream failure: " ++ show err) `shouldBe` "no stream failure"
            return (Response okStatus [] (StrictBody (BS.pack "")))

uploadRequest :: String -> RequestHead
uploadRequest filename =
    emptyRequestHead
        { requestMethod = POST
        , requestPath = ["attachments"]
        , requestHeaders = [(normaliseHeaderName (BS.pack "x-attachment-filename"), BS.pack filename)]
        }

getRequest :: [String] -> RequestHead
getRequest path =
    emptyRequestHead{requestMethod = GET, requestPath = path}

bodyText :: Response -> String
bodyText response =
    case responseBody response of
        StrictBody body -> BS.unpack body
        _ -> "<non-strict body>"

bodySize :: Response -> Maybe Int
bodySize response =
    case responseBody response of
        FileBody _ size -> Just size
        _ -> Nothing

headerValue :: String -> Response -> Maybe String
headerValue name response =
    fmap BS.unpack (lookup (normaliseHeaderName (BS.pack name)) (responseHeaders response))
