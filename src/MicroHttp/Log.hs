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
    consoleLog,
    timed,
    localTimestamp,
    localTimestampAtMillis,
    logfmtTo,
    fileLogfmtLogger,
    rotatingAppender,
    rotatingFileLogfmtLogger,
) where

import qualified Control.Concurrent.MVar as MVar
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Foreign.C.String as CStr
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Network.Socket as Socket
import qualified System.Directory as Directory
import qualified System.IO as IO
import qualified System.IO.TimeMilli as TimeMilli

-- Log rotation reuses the libc rename/unlink wrappers from MicroHttp.FileSystem
-- (MicroHs has no atomic renameFile/removeFile in System.Directory). Rotation is
-- best-effort: the wrappers' success/failure result is discarded here, so a failed
-- rename/unlink leaves the files as-is and the caller falls back to appending
-- (ADR-053). FileSystem itself checks the codes for callers that need them (ADR-061).

-- localtime converts epoch seconds to a broken-down local time (applying the
-- zone and DST); strftime renders it. The struct tm is opaque here -- localtime
-- hands its pointer straight to strftime, so no struct layout is needed.
--
-- We use the C library directly rather than Data.Time on purpose. The bundled
-- time package compiles under mhs but its local-time conversion is wrong on
-- this toolchain: getZonedTime detects the zone name but negates the offset
-- (e.g. NZST renders as -1200 with the wrong calendar day), so it logs the
-- wrong local time. localtime/strftime delegate to libc and are correct.
foreign import ccall "time.h localtime" c_localtime :: Ptr.Ptr Int -> IO (Ptr.Ptr ())
foreign import ccall "time.h strftime" c_strftime :: CStr.CString -> Int -> CStr.CString -> Ptr.Ptr () -> IO Int

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
    = RequestReceived Socket.ConnectionInfo RequestLine
    | RequestCompleted Socket.ConnectionInfo (Maybe RequestLine) Http.Status Int Int Int
    | RequestAborted Socket.ConnectionInfo (Maybe RequestLine) String Int Int

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
localTimestamp = TimeMilli.getTimeMilli >>= localTimestampAtMillis

{- | Runs an action, logging its label and how long it took.

For startup phases, so a slow one is obvious without subtracting timestamps by hand.

Times only what the action actually evaluates: a phase that returns a thunk and defers
its work will report a time that belongs to whoever forces it later. The startup phases
force their results before returning, which is what makes these numbers mean anything.
-}
timed :: String -> IO a -> IO a
timed label action = do
    started <- TimeMilli.getTimeMilli
    result <- action
    finished <- TimeMilli.getTimeMilli
    consoleLog (label ++ " " ++ show (finished - started) ++ "ms")
    pure result

-- | As 'localTimestamp' for an arbitrary epoch-milli instant (e.g. a retention cutoff).
localTimestampAtMillis :: Int -> IO String
localTimestampAtMillis millis =
    Alloc.alloca $ \timePtr -> do
        Storable.poke timePtr (millis `div` 1000)
        tmPtr <- c_localtime timePtr
        base <- strftimeWith "%Y-%m-%dT%H:%M:%S" tmPtr
        zone <- strftimeWith "%z" tmPtr
        return (base ++ "." ++ pad3 (millis `mod` 1000) ++ zone)

{- | Writes a line to stdout prefixed with the local timestamp (the same format
as the access log), then flushes. Used for startup/operational console output so
each step is timestamped and slow steps are visible.
-}
consoleLog :: String -> IO ()
consoleLog message = do
    ts <- localTimestamp
    putStrLn (ts ++ " " ++ message)
    IO.hFlush IO.stdout

-- | Renders a broken-down time with a strftime format into a fresh buffer.
strftimeWith :: String -> Ptr.Ptr () -> IO String
strftimeWith format tmPtr =
    Alloc.allocaBytes timestampBufferBytes $ \buf ->
        CStr.withCString format $ \fmt -> do
            written <- c_strftime buf timestampBufferBytes fmt tmPtr
            CStr.peekCStringLen (buf, written)

-- | Zero-pads a millisecond value (0-999) to three digits.
pad3 :: Int -> String
pad3 n
    | n < 10 = "00" ++ show n
    | n < 100 = "0" ++ show n
    | otherwise = show n

-- | The byte size of the buffer strftime renders a timestamp into.
timestampBufferBytes :: Int
timestampBufferBytes = 64

{- | A logfmt logger that appends each line to a file at the given path. It
opens the file in append mode for each line, so writes go to the end without a
shared handle; adequate for low to moderate request volume. The line is written
as bytes (the request target is byte-valued UTF-8); 'appendFile' would re-encode
it as UTF-8 and double-encode a non-ASCII target (see Verso.App).
-}
fileLogfmtLogger :: FilePath -> Logger
fileLogfmtLogger path = logfmtTo (\line -> BS.appendFile path (BS.pack (line ++ "\n")))

{- | A line sink that appends to a file, rotating it by size first (RFC-0024,
ADR-053). When the active file reaches @maxBytes@ it is rotated by a
rename-cascade -- @path -> path.1 -> ... -> path.\<keep\>@, oldest dropped -- and
the next append recreates @path@. The active file's byte size is tracked in an
'MVar' (seeded from the file on disk once), so there is no @stat@ per line; the
same 'MVar' serialises the check-rotate-append against concurrent connections, so
no line is lost or misfiled. @keep@ is expected to be at least 1.
-}
rotatingAppender :: Int -> Int -> FilePath -> IO (String -> IO ())
rotatingAppender maxBytes keep path = do
    initial <- currentFileSize path
    sizeVar <- MVar.newMVar initial
    pure $ \line -> do
        let chunk = BS.pack (line ++ "\n")
        MVar.modifyMVar_ sizeVar $ \size -> do
            rotated <- if size >= maxBytes then rotateLog path keep >> pure 0 else pure size
            BS.appendFile path chunk
            pure (rotated + BS.length chunk)

-- | A rotating-file logfmt logger: 'fileLogfmtLogger' that rotates by size.
rotatingFileLogfmtLogger :: Int -> Int -> FilePath -> IO Logger
rotatingFileLogfmtLogger maxBytes keep path = fmap logfmtTo (rotatingAppender maxBytes keep path)

-- | The current size of a file in bytes, or 0 if it does not exist.
currentFileSize :: FilePath -> IO Int
currentFileSize path = do
    exists <- Directory.doesFileExist path
    if exists then fmap BS.length (BS.readFile path) else pure 0

{- | The rename-cascade: drop @path.\<keep\>@, shift each @path.\<n\>@ up to
@path.\<n+1\>@ from the top down, then move the active @path@ to @path.1@. Each
step is guarded by existence so a missing archive is simply skipped.
-}
rotateLog :: FilePath -> Int -> IO ()
rotateLog path keep = do
    dropIfExists (archivePath path keep)
    Monad.forM_ (reverse [1 .. keep - 1]) $ \n -> renameIfExists (archivePath path n) (archivePath path (n + 1))
    renameIfExists path (archivePath path 1)

-- | The nth rotated-archive path for a log file: @path.\<n\>@.
archivePath :: FilePath -> Int -> FilePath
archivePath path n = path ++ "." ++ show n

-- | Renames a file via libc when it exists, discarding the result (best-effort).
renameIfExists :: FilePath -> FilePath -> IO ()
renameIfExists from to = do
    exists <- Directory.doesFileExist from
    Monad.when exists (Monad.void (FileSystem.renamePath from to))

-- | Unlinks a file via libc when it exists, discarding the result (best-effort).
dropIfExists :: FilePath -> IO ()
dropIfExists path = do
    exists <- Directory.doesFileExist path
    Monad.when exists (Monad.void (FileSystem.removeFilePath path))

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
                ++ show (Http.statusCode status)
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

-- | The logfmt @peer=@ field for a connection, rendering its host.
peerField :: Socket.ConnectionInfo -> String
peerField conn = " peer=" ++ renderHost (Socket.connPeerHost conn)

-- | Renders a host as a dotted-quad string (@0.0.0.0@ for 'Socket.HostAny').
renderHost :: Socket.Host -> String
renderHost Socket.HostAny = "0.0.0.0"
renderHost (Socket.HostIPv4 a b c d) =
    show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

-- | The logfmt @method=@ and @path=@ fields, dashed when no line was seen.
lineFields :: Maybe RequestLine -> String
lineFields Nothing = " method=- path=-"
lineFields (Just line) =
    " method=" ++ requestLineMethod line ++ " path=" ++ requestLineTarget line
