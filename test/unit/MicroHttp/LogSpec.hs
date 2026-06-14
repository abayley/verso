module MicroHttp.LogSpec (spec) where

import MicroHttp.Http (Status (..))
import MicroHttp.Log (AccessEvent (..), RequestLine (..), formatLogfmt)
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Log logfmt formatting" $ do
        it "given a received event, when formatting, then peer, method, and path are emitted" $
            formatLogfmt (RequestReceived peer (RequestLine "GET" "/documents/home"))
                `shouldBe` "event=RQST peer=127.0.0.1 method=GET path=/documents/home"
        it "given a completed event with a request line, when formatting, then status, sizes, and duration are emitted" $
            formatLogfmt (RequestCompleted peer (Just (RequestLine "GET" "/documents/home")) (Status 200 "OK") 42 256 12)
                `shouldBe` "event=RESP peer=127.0.0.1 method=GET path=/documents/home status=200 req_bytes=42 resp_bytes=256 dur_ms=12"
        it "given a completed event without a request line, when formatting, then method and path are dashes" $
            formatLogfmt (RequestCompleted peer Nothing (Status 400 "Bad Request") 0 12 0)
                `shouldBe` "event=RESP peer=127.0.0.1 method=- path=- status=400 req_bytes=0 resp_bytes=12 dur_ms=0"
        it "given an aborted event, when formatting, then the error label, bytes, and duration are emitted" $
            formatLogfmt (RequestAborted peer (Just (RequestLine "POST" "/upload")) "StreamReadError" 5 3)
                `shouldBe` "event=ABRT peer=127.0.0.1 method=POST path=/upload error=StreamReadError req_bytes=5 dur_ms=3"
        it "given the any host, when formatting the peer, then it renders as 0.0.0.0" $
            formatLogfmt (RequestReceived anyPeer (RequestLine "GET" "/"))
                `shouldBe` "event=RQST peer=0.0.0.0 method=GET path=/"

peer :: ConnectionInfo
peer = ConnectionInfo (HostIPv4 127 0 0 1) (Port 54321)

anyPeer :: ConnectionInfo
anyPeer = ConnectionInfo HostAny (Port 0)
