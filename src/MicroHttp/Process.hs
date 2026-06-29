{- | Run an external command as a real subprocess, capturing its stdout, stderr,
and exit status, with arguments passed as an @execvp(3)@ argument vector rather
than through a shell.

MicroHs's @System.Process@ runs everything through @libc system()@ (a shell):
arguments are space-joined with no escaping, only stdout is captured, and a
non-zero exit raises. That is unusable for invoking @git@ on paths that may
contain spaces, and gives no way to tell "nothing to commit" from a real
failure. This module is the framework escape hatch -- the same libc-FFI pattern
'MicroHttp.FileSystem' uses -- built on @fork(2)@ + @execvp(3)@ + @waitpid(2)@.

Because arguments reach the child as a @char *const argv[]@ vector, shell
metacharacters, spaces, and quotes are passed verbatim and command injection is
structurally impossible: the shell never parses them (RFC-0032, ADR-070).

The child's stdout and stderr are redirected to temporary capture files (via
@dup2(2)@) rather than pipes, so there is no pipe-deadlock to manage; the parent
@waitpid@s (no zombies) and reads the files back. Output is 'BS.ByteString' for
byte-exactness, so a captured page body round-trips losslessly (ADR-038).

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
import qualified System.Directory as Directory
import qualified System.Exit as Exit
import qualified System.IO as IO

-- fork(2)/execvp(3)/waitpid(2)/dup2(2): the POSIX process primitives, available
-- identically on macOS and Linux. execvp resolves the executable via PATH and
-- takes an argv vector, so no shell and no argument quoting are involved.
foreign import ccall "unistd.h fork" c_fork :: IO CTypes.CInt
foreign import ccall "unistd.h execvp" c_execvp :: CStr.CString -> Ptr.Ptr CStr.CString -> IO CTypes.CInt
foreign import ccall "unistd.h dup2" c_dup2 :: CTypes.CInt -> CTypes.CInt -> IO CTypes.CInt
foreign import ccall "unistd.h close" c_close :: CTypes.CInt -> IO CTypes.CInt
foreign import ccall "unistd.h chdir" c_chdir :: CStr.CString -> IO CTypes.CInt
foreign import ccall "unistd.h _exit" c_exit :: CTypes.CInt -> IO ()
foreign import ccall "sys/wait.h waitpid" c_waitpid :: CTypes.CInt -> Ptr.Ptr CTypes.CInt -> CTypes.CInt -> IO CTypes.CInt

-- creat(3) creates/truncates the output capture file for writing without naming
-- O_CREAT/O_TRUNC (whose values differ by platform); open(2) with flag 0 is
-- O_RDONLY everywhere, used to feed the stdin capture file to the child.
foreign import ccall "fcntl.h creat" c_creat :: CStr.CString -> CTypes.CInt -> IO CTypes.CInt
foreign import ccall "fcntl.h open" c_open :: CStr.CString -> CTypes.CInt -> IO CTypes.CInt

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

Arguments are passed to @execvp@ unmodified -- spaces, quotes, and shell
metacharacters reach the program literally and are never interpreted. When
@mCwd@ is 'Just', the child @chdir@s there before exec; when 'Nothing', it runs
in the server's working directory. When @mStdin@ is 'Just', those bytes are the
child's standard input; when 'Nothing', the child inherits the server's stdin.
-}
runProcess :: FilePath -> [String] -> Maybe FilePath -> Maybe BS.ByteString -> IO ProcResult
runProcess executable args mCwd mStdin = do
    tmp <- Directory.getTemporaryDirectory
    outPath <- reserveTempFile tmp "micro-http-out"
    errPath <- reserveTempFile tmp "micro-http-err"
    inPath <- case mStdin of
        Nothing -> pure Nothing
        Just bytes -> do
            p <- reserveTempFile tmp "micro-http-in"
            BS.writeFile p bytes
            pure (Just p)
    result <- spawnAndWait executable args mCwd outPath errPath inPath
    cleanup (outPath : errPath : maybe [] pure inPath)
    pure result

{- | Forks, redirects the child's stdio to the capture files, execs, and waits.
The output capture files are opened in the parent so the parent can read them
after the child exits; the child only performs @dup2@/@chdir@/@execvp@ between
fork and exec (all async-signal-safe).
-}
spawnAndWait :: FilePath -> [String] -> Maybe FilePath -> FilePath -> FilePath -> Maybe FilePath -> IO ProcResult
spawnAndWait executable args mCwd outPath errPath mInPath = do
    outFd <- CStr.withCString outPath (`c_creat` 0o600)
    errFd <- CStr.withCString errPath (`c_creat` 0o600)
    inFd <- case mInPath of
        Nothing -> pure (-1)
        Just p -> CStr.withCString p (`c_open` 0) -- 0 == O_RDONLY
    pid <- c_fork
    if pid < 0
        then do
            mapM_ closeFd [outFd, errFd, inFd]
            pure (ProcResult (Exit.ExitFailure 127) BS.empty (BS.pack "fork failed"))
        else
            if pid == 0
                then do
                    runChild executable args mCwd outFd errFd inFd
                    c_exit 127 -- only reached if exec failed
                    pure (ProcResult (Exit.ExitFailure 127) BS.empty BS.empty) -- unreachable; satisfies the type
                else do
                    mapM_ closeFd [outFd, errFd, inFd]
                    code <- waitFor pid
                    out <- BS.readFile outPath
                    err <- BS.readFile errPath
                    pure (ProcResult code out err)

{- | The child half of the fork: point stdout\/stderr (and stdin, when supplied)
at the capture files, change directory if requested, then @execvp@. Returns only
if exec fails, leaving the caller to @_exit@.
-}
runChild :: FilePath -> [String] -> Maybe FilePath -> CTypes.CInt -> CTypes.CInt -> CTypes.CInt -> IO ()
runChild executable args mCwd outFd errFd inFd = do
    _ <- c_dup2 outFd 1
    _ <- c_dup2 errFd 2
    Monad.when (inFd >= 0) (Monad.void (c_dup2 inFd 0))
    mapM_ closeFd [outFd, errFd, inFd]
    case mCwd of
        Nothing -> pure ()
        Just dir -> Monad.void (CStr.withCString dir c_chdir)
    -- argv[0] is the program name by convention, so the executable leads the vector.
    withCStrings (executable : args) $ \cstrs ->
        Array.withArray0 Ptr.nullPtr cstrs $ \argv ->
            CStr.withCString executable $ \exe ->
                Monad.void (c_execvp exe argv)

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
reserveTempFile :: FilePath -> String -> IO FilePath
reserveTempFile dir template = do
    (path, handle) <- IO.openTempFile dir template
    IO.hClose handle
    pure path

-- | Removes the given temporary files, ignoring any that are already gone.
cleanup :: [FilePath] -> IO ()
cleanup = mapM_ removeQuietly
  where
    removeQuietly p = do
        exists <- Directory.doesFileExist p
        Monad.when exists (Directory.removeFile p)

{- | Marshals a list of 'String's to a list of NUL-terminated C strings that stay
valid for the duration of the continuation (the @execvp@ argv lives only until
exec replaces the process image).
-}
withCStrings :: [String] -> ([CStr.CString] -> IO a) -> IO a
withCStrings [] k = k []
withCStrings (s : ss) k = CStr.withCString s (\c -> withCStrings ss (\cs -> k (c : cs)))
