{- | Run an external command as a real subprocess, capturing its stdout, stderr,
and exit status, with arguments passed as an exec argument vector rather than
through a shell.

MicroHs's @System.Process@ runs everything through @libc system()@ (a shell):
arguments are space-joined with no escaping, only stdout is captured, and a
non-zero exit raises. That is unusable for invoking @git@ on paths that may
contain spaces, and gives no way to tell "nothing to commit" from a real
failure. This module is the framework escape hatch -- the same libc-FFI pattern
'MicroHttp.FileSystem' uses -- built on @posix_spawnp(3)@ + @waitpid(2)@
(cbits\/microhttp_process.c).

@posix_spawn@ rather than @fork(2)@ + @execvp(3)@, deliberately: the hosting
process may run native thread pools (a search engine's tokio runtime, ONNX
workers) whose threads do not survive fork. A forked child that runs any
interpreter code before exec can resume a green thread whose next step blocks
on one of those vanished workers, deadlocking the child in the parent's
@waitpid@ and wedging the whole server. @posix_spawn@ goes straight to exec
with no user code in the child, so the hazard cannot arise (ADR-0078).

Because arguments reach the child as a @char *const argv[]@ vector, shell
metacharacters, spaces, and quotes are passed verbatim and command injection is
structurally impossible: the shell never parses them (RFC-0032, ADR-0070).

The child's stdout and stderr are redirected to temporary capture files (via
spawn file actions) rather than pipes, so there is no pipe-deadlock to manage;
the parent @waitpid@s (no zombies) and reads the files back. Output is
'BS.ByteString' for byte-exactness, so a captured page body round-trips
losslessly (ADR-0038).

The capture mechanism uses @creat(3)@ for the output files and @open(2)@ with
@O_RDONLY@ (the portable @0@ flag) for stdin, sidestepping the platform-divergent
@O_CREAT@/@O_TRUNC@ flag values; the @waitpid@ status is decoded with the
@WEXITSTATUS@ bit layout, which is identical on macOS and Linux (RFC-0032).
-}
module MicroHttp.Process (
    ProcResult (..),
    runProcess,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Marshal.Array as Array
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable
import qualified MicroHttp.FileSystem as FileSystem
import qualified System.Directory as Directory
import qualified System.Exit as Exit

-- mhp_spawn wraps posix_spawnp(3) and its opaque file-actions setup (redirect
-- stdio, chdir, exec) in one C call; it resolves the executable via PATH and
-- takes an argv vector, so no shell and no argument quoting are involved.
-- waitpid(2) is identical on macOS and Linux and imported directly.
foreign import ccall "microhttp_process.h mhp_spawn" c_spawn :: CStr.CString -> Ptr.Ptr CStr.CString -> CStr.CString -> CTypes.CLong -> CTypes.CLong -> CTypes.CLong -> IO CTypes.CLong
foreign import ccall "unistd.h close" c_close :: CTypes.CInt -> IO CTypes.CInt
foreign import ccall "sys/wait.h waitpid" c_waitpid :: CTypes.CInt -> Ptr.Ptr CTypes.CInt -> CTypes.CInt -> IO CTypes.CInt

-- creat(3) creates/truncates the output capture file for writing without naming
-- O_CREAT/O_TRUNC (whose values differ by platform); open(2) with flag 0 is
-- O_RDONLY everywhere, used to feed the stdin capture file to the child.
foreign import ccall "fcntl.h creat" c_creat :: CStr.CString -> CTypes.CInt -> IO CTypes.CInt

-- open(2) is variadic, so it goes through the fixed-arity wrapper (see microhttp_fs.h).
foreign import ccall "microhttp_fs.h mhfs_open_read" c_openRead :: CStr.CString -> IO CTypes.CLong

-- | The outcome of a subprocess: its exit status and the bytes it wrote to stdout and stderr.
data ProcResult = ProcResult
    { procExit :: Exit.ExitCode
    , procOut :: BS.ByteString
    , procErr :: BS.ByteString
    }
    deriving (Eq, Show)

{- | Runs @executable@ (resolved via @PATH@) with @args@ as an exact argument
vector, optionally in a working directory and with stdin supplied, and returns
its exit status and captured stdout/stderr.

Arguments are passed to @posix_spawnp@ unmodified -- spaces, quotes, and shell
metacharacters reach the program literally and are never interpreted. When
@mCwd@ is 'Just', the child @chdir@s there before exec; when 'Nothing', it runs
in the server's working directory. When @mStdin@ is 'Just', those bytes are the
child's standard input; when 'Nothing', the child inherits the server's stdin.
-}
runProcess :: FilePath -> [String] -> Maybe FilePath -> Maybe BS.ByteString -> IO ProcResult
runProcess executable args mCwd mStdin = do
    tmp <- Directory.getTemporaryDirectory
    outPath <- FileSystem.uniqueTempPath tmp "micro-http-out"
    errPath <- FileSystem.uniqueTempPath tmp "micro-http-err"
    inPath <- case mStdin of
        Nothing -> pure Nothing
        Just bytes -> do
            p <- FileSystem.uniqueTempPath tmp "micro-http-in"
            BS.writeFile p bytes
            pure (Just p)
    result <- spawnAndWait executable args mCwd outPath errPath inPath
    cleanup (outPath : errPath : maybe [] pure inPath)
    pure result

{- | Spawns the child with its stdio redirected to the capture files (via
@posix_spawn@ file actions), then waits. The capture files are opened in the
parent so it can read them after the child exits; no code of ours runs in the
child. A spawn failure (executable not found, bad working directory) reports
exit 127, matching the exec-failure convention.
-}
spawnAndWait :: FilePath -> [String] -> Maybe FilePath -> FilePath -> FilePath -> Maybe FilePath -> IO ProcResult
spawnAndWait executable args mCwd outPath errPath mInPath = do
    outFd <- CStr.withCString outPath (`c_creat` 0o600)
    errFd <- CStr.withCString errPath (`c_creat` 0o600)
    inFd <- case mInPath of
        Nothing -> pure (-1)
        Just p -> fmap fromIntegral (CStr.withCString p c_openRead)
    pid <- spawn executable args mCwd outFd errFd inFd
    mapM_ closeFd [outFd, errFd, inFd]
    if pid < 0
        then pure (ProcResult (Exit.ExitFailure 127) BS.empty (BS.pack ("spawn failed (errno " ++ show (negate pid) ++ ")")))
        else do
            code <- waitFor (fromIntegral pid)
            out <- BS.readFile outPath
            err <- BS.readFile errPath
            pure (ProcResult code out err)

{- | Marshals the argv vector and optional working directory and calls
@mhp_spawn@, returning the child pid (>= 0) or a negated @errno@ (< 0).
-}
spawn :: FilePath -> [String] -> Maybe FilePath -> CTypes.CInt -> CTypes.CInt -> CTypes.CInt -> IO CTypes.CLong
spawn executable args mCwd outFd errFd inFd =
    -- argv[0] is the program name by convention, so the executable leads the vector.
    withCStrings (executable : args) $ \cstrs ->
        Array.withArray0 Ptr.nullPtr cstrs $ \argv ->
            CStr.withCString executable $ \exe ->
                withMaybeCString mCwd $ \cwd ->
                    c_spawn exe argv cwd (fromIntegral outFd) (fromIntegral errFd) (fromIntegral inFd)

{- | Blocks until @pid@ exits and decodes its @waitpid@ status into an 'Exit.ExitCode':
'Exit.ExitSuccess' for a zero exit, otherwise 'Exit.ExitFailure' with the exit
code (or @128 + signal@ when the child was killed by a signal).
-}
waitFor :: CTypes.CInt -> IO Exit.ExitCode
waitFor pid = Alloc.alloca $ \statusPtr -> do
    _ <- c_waitpid pid statusPtr 0
    status <- Storable.peek statusPtr
    let s = fromIntegral status :: Int
        termSig = s `mod` 128 -- low 7 bits: 0 when the child exited normally
        exitCode = (s `div` 256) `mod` 256 -- WEXITSTATUS: bits 8..15
        code = if termSig == 0 then exitCode else 128 + termSig
    pure (if code == 0 then Exit.ExitSuccess else Exit.ExitFailure code)

-- | Closes a file descriptor, ignoring the result and any already-closed (@-1@) sentinel.
closeFd :: CTypes.CInt -> IO ()
closeFd fd = Monad.when (fd >= 0) (Monad.void (c_close fd))

{- | Creates a fresh, uniquely named temporary file and returns its path (the
handle is closed immediately; only the path is used). Wraps @openTempFile@ so
concurrent runs never collide on a capture file.
-}

-- | Removes the given temporary files, ignoring any that are already gone.
cleanup :: [FilePath] -> IO ()
cleanup = mapM_ removeQuietly
  where
    removeQuietly p = do
        exists <- Directory.doesFileExist p
        Monad.when exists (Directory.removeFile p)

{- | Marshals a list of 'String's to a list of NUL-terminated C strings that stay
valid for the duration of the continuation (@posix_spawn@ copies the argv
before it returns).
-}
withCStrings :: [String] -> ([CStr.CString] -> IO a) -> IO a
withCStrings [] k = k []
withCStrings (s : ss) k = CStr.withCString s (\c -> withCStrings ss (\cs -> k (c : cs)))

-- | Like 'CStr.withCString' for an optional string, passing NULL for 'Nothing'.
withMaybeCString :: Maybe String -> (CStr.CString -> IO a) -> IO a
withMaybeCString Nothing k = k Ptr.nullPtr
withMaybeCString (Just s) k = CStr.withCString s k
