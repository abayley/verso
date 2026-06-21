module MicroHttp.LogSpec (spec) where

import Control.Monad (filterM)
import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf)
import MicroHttp.Http (Status (..))
import MicroHttp.Log (AccessEvent (..), RequestLine (..), formatLogfmt, localTimestamp, rotatingAppender)
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.IO.TimeMilli (getTimeMilli)
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

        describe "log rotation (RFC-0024)" $ do
            it "given the active file past the threshold, when appending, then it rotates to .1 and keeps writing" $ do
                path <- freshLogPath "threshold"
                append <- rotatingAppender 30 3 path
                append "first-line-aaaa"
                append "second-line-bbbb"
                -- The third append sees the file already past 30 bytes, so it rotates first.
                append "third-line-cccc"
                archived <- BS.unpack <$> BS.readFile (path ++ ".1")
                active <- BS.unpack <$> BS.readFile path
                ("first-line-aaaa" `isInfixOf` archived) `shouldBe` True
                ("second-line-bbbb" `isInfixOf` archived) `shouldBe` True
                active `shouldBe` "third-line-cccc\n"

            it "given repeated rotations, when they exceed keep, then the cascade shifts archives and drops the oldest" $ do
                path <- freshLogPath "cascade"
                append <- rotatingAppender 10 2 path
                -- Each line is over the 10-byte threshold, so every append after the first rotates.
                mapM_ append ["rotation-001", "rotation-002", "rotation-003", "rotation-004"]
                e1 <- doesFileExist (path ++ ".1")
                e2 <- doesFileExist (path ++ ".2")
                e3 <- doesFileExist (path ++ ".3")
                (e1, e2, e3) `shouldBe` (True, True, False)

            it "given many appends across rotations within keep, when read back, then no line is lost" $ do
                path <- freshLogPath "noloss"
                append <- rotatingAppender 12 20 path
                let messages = map (\n -> "line-" ++ show n) [1 .. 15 :: Int]
                mapM_ append messages
                logged <- readAllLogs path 20
                length logged `shouldBe` length messages
                logged `shouldBe` messages

ts :: String
ts = "2026-06-15T14:30:00.123+1200"

peer :: ConnectionInfo
peer = ConnectionInfo (HostIPv4 127 0 0 1) (Port 54321)

anyPeer :: ConnectionInfo
anyPeer = ConnectionInfo HostAny (Port 0)

{- | A unique log path under build/ per run (millisecond-stamped), so rotation
tests never see stale archives from a previous run.
-}
freshLogPath :: String -> IO FilePath
freshLogPath name = do
    stamp <- getTimeMilli
    let dir = "build/log-rotation-spec/" ++ show stamp ++ "-" ++ name
    createDirectoryIfMissing True dir
    pure (dir ++ "/server.log")

{- | The logged lines across the active file and its archives, in chronological
order: the highest-numbered (oldest) archive first, down to @.1@, then the active
file last.
-}
readAllLogs :: FilePath -> Int -> IO [String]
readAllLogs path keep = do
    let candidates = [path ++ "." ++ show n | n <- reverse [1 .. keep]] ++ [path]
    existing <- filterM doesFileExist candidates
    contents <- mapM (fmap BS.unpack . BS.readFile) existing
    pure (concatMap lines contents)
