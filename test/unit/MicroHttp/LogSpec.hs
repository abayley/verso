module MicroHttp.LogSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Network.Socket as Socket
import qualified System.Directory as Directory
import qualified System.IO.TimeMilli as TimeMilli
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Log logfmt formatting" $ do
        it "given a received event, when formatting, then a timestamp, peer, method, and path are emitted" $
            Log.formatLogfmt ts (Log.RequestReceived peer (Log.RequestLine "GET" "/documents/home"))
                `shouldBe` "ts=" ++ ts ++ " event=RQST peer=127.0.0.1 method=GET path=/documents/home"
        it "given a completed event with a request line, when formatting, then status, sizes, and duration are emitted" $
            Log.formatLogfmt ts (Log.RequestCompleted peer (Just (Log.RequestLine "GET" "/documents/home")) (Http.Status 200 "OK") 42 256 12)
                `shouldBe` "ts=" ++ ts ++ " event=RESP peer=127.0.0.1 method=GET path=/documents/home status=200 req_bytes=42 resp_bytes=256 dur_ms=12"
        it "given a completed event without a request line, when formatting, then method and path are dashes" $
            Log.formatLogfmt ts (Log.RequestCompleted peer Nothing (Http.Status 400 "Bad Request") 0 12 0)
                `shouldBe` "ts=" ++ ts ++ " event=RESP peer=127.0.0.1 method=- path=- status=400 req_bytes=0 resp_bytes=12 dur_ms=0"
        it "given an aborted event, when formatting, then the error label, bytes, and duration are emitted" $
            Log.formatLogfmt ts (Log.RequestAborted peer (Just (Log.RequestLine "POST" "/upload")) "StreamReadError" 5 3)
                `shouldBe` "ts=" ++ ts ++ " event=ABRT peer=127.0.0.1 method=POST path=/upload error=StreamReadError req_bytes=5 dur_ms=3"
        it "given the any host, when formatting the peer, then it renders as 0.0.0.0" $
            Log.formatLogfmt ts (Log.RequestReceived anyPeer (Log.RequestLine "GET" "/"))
                `shouldBe` "ts=" ++ ts ++ " event=RQST peer=0.0.0.0 method=GET path=/"
        it "given the local clock, when timestamping, then a date-time with a zone offset is produced" $ do
            stamp <- Log.localTimestamp
            -- Shape only (the value is the wall clock): ISO-ish local time with a
            -- millisecond fraction and a numeric zone offset, e.g.
            -- 2026-06-15T14:30:00.123+1200. We assert structure, not the moment.
            ('T' `elem` stamp) `shouldBe` True
            ("." `List.isInfixOf` stamp) `shouldBe` True
            any (`elem` "+-") (drop 11 stamp) `shouldBe` True

        describe "log rotation (RFC-0024)" $ do
            it "given the active file past the threshold, when appending, then it rotates to .1 and keeps writing" $ do
                path <- freshLogPath "threshold"
                append <- Log.rotatingAppender 30 3 path
                append "first-line-aaaa"
                append "second-line-bbbb"
                -- The third append sees the file already past 30 bytes, so it rotates first.
                append "third-line-cccc"
                archived <- BS.unpack <$> BS.readFile (path ++ ".1")
                active <- BS.unpack <$> BS.readFile path
                ("first-line-aaaa" `List.isInfixOf` archived) `shouldBe` True
                ("second-line-bbbb" `List.isInfixOf` archived) `shouldBe` True
                active `shouldBe` "third-line-cccc\n"

            it "given an active file already past the threshold, when a new appender first appends, then it rotates before writing" $ do
                path <- freshLogPath "seeded"
                BS.writeFile path (BS.pack (replicate 40 'x' ++ "\n"))
                append <- Log.rotatingAppender 30 3 path
                append "fresh-line"
                archived <- BS.unpack <$> BS.readFile (path ++ ".1")
                active <- BS.unpack <$> BS.readFile path
                (replicate 40 'x' `List.isInfixOf` archived) `shouldBe` True
                active `shouldBe` "fresh-line\n"

            it "given repeated rotations, when they exceed keep, then the cascade shifts archives and drops the oldest" $ do
                path <- freshLogPath "cascade"
                append <- Log.rotatingAppender 10 2 path
                -- Each line is over the 10-byte threshold, so every append after the first rotates.
                mapM_ append ["rotation-001", "rotation-002", "rotation-003", "rotation-004"]
                e1 <- Directory.doesFileExist (path ++ ".1")
                e2 <- Directory.doesFileExist (path ++ ".2")
                e3 <- Directory.doesFileExist (path ++ ".3")
                (e1, e2, e3) `shouldBe` (True, True, False)

            it "given many appends across rotations within keep, when read back, then no line is lost" $ do
                path <- freshLogPath "noloss"
                append <- Log.rotatingAppender 12 20 path
                let messages = map (\n -> "line-" ++ show n) [1 .. 15 :: Int]
                mapM_ append messages
                logged <- readAllLogs path 20
                length logged `shouldBe` length messages
                logged `shouldBe` messages

ts :: String
ts = "2026-06-15T14:30:00.123+1200"

peer :: Socket.ConnectionInfo
peer = Socket.ConnectionInfo (Socket.HostIPv4 127 0 0 1) (Socket.Port 54321)

anyPeer :: Socket.ConnectionInfo
anyPeer = Socket.ConnectionInfo Socket.HostAny (Socket.Port 0)

{- | A unique log path under build/ per run (millisecond-stamped), so rotation
tests never see stale archives from a previous run.
-}
freshLogPath :: String -> IO FilePath
freshLogPath name = do
    stamp <- TimeMilli.getTimeMilli
    let dir = "build/log-rotation-spec/" ++ show stamp ++ "-" ++ name
    Directory.createDirectoryIfMissing True dir
    pure (dir ++ "/server.log")

{- | The logged lines across the active file and its archives, in chronological
order: the highest-numbered (oldest) archive first, down to @.1@, then the active
file last.
-}
readAllLogs :: FilePath -> Int -> IO [String]
readAllLogs path keep = do
    let candidates = [path ++ "." ++ show n | n <- reverse [1 .. keep]] ++ [path]
    existing <- Monad.filterM Directory.doesFileExist candidates
    contents <- mapM (fmap BS.unpack . BS.readFile) existing
    pure (concatMap lines contents)
