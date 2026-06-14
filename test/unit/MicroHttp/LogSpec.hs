module MicroHttp.LogSpec (spec) where

import Data.List (isInfixOf)
import MicroHttp.Http (Status (..))
import MicroHttp.Log (AccessEvent (..), RequestLine (..), formatLogfmt, localTimestamp)
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Log logfmt formatting" $ do
        it "given a received event, when formatting, then a timestamp, peer, method, and path are emitted" $
            formatLogfmt ts (RequestReceived peer (RequestLine "GET" "/documents/home"))
                `shouldBe` "ts=" ++ ts ++ " event=RQST peer=127.0.0.1 method=GET path=/documents/home"
        it "given a completed event with a request line, when formatting, then status, sizes, and duration are emitted" $
            formatLogfmt ts (RequestCompleted peer (Just (RequestLine "GET" "/documents/home")) (Status 200 "OK") 42 256 12)
                `shouldBe` "ts=" ++ ts ++ " event=RESP peer=127.0.0.1 method=GET path=/documents/home status=200 req_bytes=42 resp_bytes=256 dur_ms=12"
        it "given a completed event without a request line, when formatting, then method and path are dashes" $
            formatLogfmt ts (RequestCompleted peer Nothing (Status 400 "Bad Request") 0 12 0)
                `shouldBe` "ts=" ++ ts ++ " event=RESP peer=127.0.0.1 method=- path=- status=400 req_bytes=0 resp_bytes=12 dur_ms=0"
        it "given an aborted event, when formatting, then the error label, bytes, and duration are emitted" $
            formatLogfmt ts (RequestAborted peer (Just (RequestLine "POST" "/upload")) "StreamReadError" 5 3)
                `shouldBe` "ts=" ++ ts ++ " event=ABRT peer=127.0.0.1 method=POST path=/upload error=StreamReadError req_bytes=5 dur_ms=3"
        it "given the any host, when formatting the peer, then it renders as 0.0.0.0" $
            formatLogfmt ts (RequestReceived anyPeer (RequestLine "GET" "/"))
                `shouldBe` "ts=" ++ ts ++ " event=RQST peer=0.0.0.0 method=GET path=/"
        it "given the local clock, when timestamping, then a date-time with a zone offset is produced" $ do
            stamp <- localTimestamp
            -- Shape only (the value is the wall clock): ISO-ish local time with a
            -- millisecond fraction and a numeric zone offset, e.g.
            -- 2026-06-15T14:30:00.123+1200. We assert structure, not the moment.
            ('T' `elem` stamp) `shouldBe` True
            ("." `isInfixOf` stamp) `shouldBe` True
            any (`elem` "+-") (drop 11 stamp) `shouldBe` True

ts :: String
ts = "2026-06-15T14:30:00.123+1200"

peer :: ConnectionInfo
peer = ConnectionInfo (HostIPv4 127 0 0 1) (Port 54321)

anyPeer :: ConnectionInfo
anyPeer = ConnectionInfo HostAny (Port 0)
