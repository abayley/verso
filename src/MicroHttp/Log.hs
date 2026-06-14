{- | The server's access-log vocabulary. Logging is a middleware
(RFC-0012): 'MicroHttp.Middleware.logRequests' taps the request stream for the
first line and observes the response, emitting these events. The 'Logger' sink
and the line format are injected, so the destination and format are swappable;
'formatLogfmt' is the default logfmt format and 'logfmtTo' / 'fileLogfmtLogger'
build loggers from a line sink.

An event carries the peer ('ConnectionInfo') and the request line as method and
target strings (what the logging middleware can cheaply tap from the first
line), not a fully parsed 'RequestHead'.
-}
module MicroHttp.Log (
    AccessEvent (..),
    RequestLine (..),
    Logger,
    nullLogger,
    formatLogfmt,
    localTimestamp,
    logfmtTo,
    fileLogfmtLogger,
) where

import Foreign.C.String (CString, peekCStringLen, withCString)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (poke)
import MicroHttp.Http (Status (..))
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), Port (..))
import System.IO (appendFile)
import System.IO.TimeMilli (getTimeMilli)

-- localtime converts epoch seconds to a broken-down local time (applying the
-- zone and DST); strftime renders it. The struct tm is opaque here -- localtime
-- hands its pointer straight to strftime, so no struct layout is needed.
--
-- We use the C library directly rather than Data.Time on purpose. The bundled
-- time package compiles under mhs but its local-time conversion is wrong on
-- this toolchain: getZonedTime detects the zone name but negates the offset
-- (e.g. NZST renders as -1200 with the wrong calendar day), so it logs the
-- wrong local time. localtime/strftime delegate to libc and are correct.
foreign import ccall "time.h localtime" c_localtime :: Ptr Int -> IO (Ptr ())
foreign import ccall "time.h strftime" c_strftime :: CString -> Int -> CString -> Ptr () -> IO Int

-- | An injected access-log sink.
type Logger = AccessEvent -> IO ()

-- | The request's first line, as tapped: the method token and the target.
data RequestLine = RequestLine
    { requestLineMethod :: String
    , requestLineTarget :: String
    }

{- | A logged moment in a connection's life, carrying the peer. The request
line is 'Nothing' on the terminal event when no first line was seen (a peer
that connected and stalled). 'RequestCompleted' carries request bytes, response
bytes, and the duration in milliseconds; 'RequestAborted' carries request bytes
and the duration.
-}
data AccessEvent
    = RequestReceived ConnectionInfo RequestLine
    | RequestCompleted ConnectionInfo (Maybe RequestLine) Status Int Int Int
    | RequestAborted ConnectionInfo (Maybe RequestLine) String Int Int

-- | The no-op logger: logging disabled.
nullLogger :: Logger
nullLogger _ = pure ()

{- | Builds a logger that stamps each event with the local time, formats it as
logfmt, and writes the line. The timestamp is captured when the event is logged,
which is the moment it occurs (the middleware logs synchronously).
-}
logfmtTo :: (String -> IO ()) -> Logger
logfmtTo emit event = do
    ts <- localTimestamp
    emit (formatLogfmt ts event)

{- | The current wall-clock time in local time as
@YYYY-MM-DDThh:mm:ss.mmm±zzzz@ (ISO-8601-ish, with a millisecond fraction and a
numeric zone offset, no internal spaces so it is one logfmt token). Built from
@gettimeofday@ epoch millis via @localtime@/@strftime@, so it follows the host's
zone and DST.
-}
localTimestamp :: IO String
localTimestamp = do
    millis <- getTimeMilli
    alloca $ \timePtr -> do
        poke timePtr (millis `div` 1000)
        tmPtr <- c_localtime timePtr
        base <- strftimeWith "%Y-%m-%dT%H:%M:%S" tmPtr
        zone <- strftimeWith "%z" tmPtr
        return (base ++ "." ++ pad3 (millis `mod` 1000) ++ zone)

-- | Renders a broken-down time with a strftime format into a fresh buffer.
strftimeWith :: String -> Ptr () -> IO String
strftimeWith format tmPtr =
    allocaBytes timestampBufferBytes $ \buf ->
        withCString format $ \fmt -> do
            written <- c_strftime buf timestampBufferBytes fmt tmPtr
            peekCStringLen (buf, written)

-- | Zero-pads a millisecond value (0-999) to three digits.
pad3 :: Int -> String
pad3 n
    | n < 10 = "00" ++ show n
    | n < 100 = "0" ++ show n
    | otherwise = show n

timestampBufferBytes :: Int
timestampBufferBytes = 64

{- | A logfmt logger that appends each line to a file at the given path. It
opens the file in append mode for each line, so writes go to the end without a
shared handle; adequate for low to moderate request volume.
-}
fileLogfmtLogger :: FilePath -> Logger
fileLogfmtLogger path = logfmtTo (\line -> appendFile path (line ++ "\n"))

-- | Renders an access event as a single logfmt line, stamped with @ts@ first.
formatLogfmt :: String -> AccessEvent -> String
formatLogfmt ts event =
    "ts=" ++ ts ++ " " ++ eventFields
  where
    eventFields = case event of
        RequestReceived conn line ->
            "event=RQST" ++ peerField conn ++ lineFields (Just line)
        RequestCompleted conn line status reqBytes respBytes durationMillis ->
            "event=RESP"
                ++ peerField conn
                ++ lineFields line
                ++ " status="
                ++ show (statusCode status)
                ++ " req_bytes="
                ++ show reqBytes
                ++ " resp_bytes="
                ++ show respBytes
                ++ " dur_ms="
                ++ show durationMillis
        RequestAborted conn line reason reqBytes durationMillis ->
            "event=ABRT"
                ++ peerField conn
                ++ lineFields line
                ++ " error="
                ++ reason
                ++ " req_bytes="
                ++ show reqBytes
                ++ " dur_ms="
                ++ show durationMillis

peerField :: ConnectionInfo -> String
peerField conn = " peer=" ++ renderHost (connPeerHost conn)

renderHost :: Host -> String
renderHost HostAny = "0.0.0.0"
renderHost (HostIPv4 a b c d) =
    show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

lineFields :: Maybe RequestLine -> String
lineFields Nothing = " method=- path=-"
lineFields (Just line) =
    " method=" ++ requestLineMethod line ++ " path=" ++ requestLineTarget line
