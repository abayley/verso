module MicroHttp.LogSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http (Method (..), RequestHead (..), Status (..))
import MicroHttp.Log (AccessEvent (..), formatLogfmt)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Log logfmt formatting" $ do
        it "given a received event, when formatting, then the method and path are emitted" $
            formatLogfmt (RequestReceived (headFor GET ["documents", "home"]))
                `shouldBe` "event=request.received method=GET path=/documents/home"
        it "given a completed event with a head, when formatting, then status, bytes, and duration are emitted" $
            formatLogfmt (RequestCompleted (Just (headFor GET ["documents", "home"])) (Status 200 "OK") 1234 12)
                `shouldBe` "event=request.completed method=GET path=/documents/home status=200 bytes=1234 dur_ms=12"
        it "given a completed event without a head, when formatting, then method and path are dashes" $
            formatLogfmt (RequestCompleted Nothing (Status 400 "Bad Request") 12 0)
                `shouldBe` "event=request.completed method=- path=- status=400 bytes=12 dur_ms=0"
        it "given a root path, when formatting, then the path is a single slash" $
            formatLogfmt (RequestReceived (headFor GET []))
                `shouldBe` "event=request.received method=GET path=/"
        it "given an aborted event with a head, when formatting, then the error label and duration are emitted" $
            formatLogfmt (RequestAborted (Just (headFor POST ["upload"])) "ServerWriteFailed" 30000)
                `shouldBe` "event=request.aborted method=POST path=/upload error=ServerWriteFailed dur_ms=30000"
        it "given an aborted event without a head, when formatting, then method and path are dashes" $
            formatLogfmt (RequestAborted Nothing "ServerReadFailed" 5)
                `shouldBe` "event=request.aborted method=- path=- error=ServerReadFailed dur_ms=5"

headFor :: Method -> [String] -> RequestHead
headFor method path =
    RequestHead
        { requestMethod = method
        , requestPath = path
        , requestQuery = []
        , requestHeaders = []
        , requestRawPath = BS.pack ("/" ++ rawFrom path)
        }
  where
    rawFrom [] = ""
    rawFrom segments = joinSlash segments

joinSlash :: [String] -> String
joinSlash [] = ""
joinSlash [segment] = segment
joinSlash (segment : rest) = segment ++ "/" ++ joinSlash rest
