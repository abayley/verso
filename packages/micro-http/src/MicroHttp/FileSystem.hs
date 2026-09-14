{- | The server's filesystem primitives for in-server move and delete (RFC-0027) and
the link index (RFC-0029): @rename(2)@, @unlink(2)@, @rmdir(2)@, and @stat(2)@ via
the @cbits/microhttp_fs.c@ wrappers, because MicroHs's @System.Directory@ has no
atomic file rename/remove and no modification time (the same libc escape hatch
'MicroHttp.Log' uses for rotation, now consolidated here).

Unlike 'MicroHttp.Log', these wrappers __report the failure__: each returns
@Right@ only when the syscall succeeded, and @Left errno@ otherwise, so a failed
move or remove surfaces to the caller with its reason -- ENOENT vs EACCES vs
ENOTEMPTY -- rather than silently leaving the tree inconsistent (the RFC-0027
reliability contract, ADR-0061). The C wrappers fold the return code and @errno@
into one value, so no other green thread's C call can clobber @errno@ between
the syscall and its errno read.

The path arguments are already-resolved filesystem paths; callers validate
tree-relative inputs with 'MicroHttp.Static.safeComponent' (via
@resolveStaticPath@) __before__ calling here, so these primitives perform no path
validation of their own.

The 'fileStat' field offsets are __macOS-specific__ (the @struct stat@ layout is
platform-dependent). They are isolated behind named constants so the cross-platform
portability RFC can parameterise them; ADR-0067.
-}
module MicroHttp.FileSystem (
    Errno (..),
    isDoesNotExist,
    renamePath,
    removeFilePath,
    removeEmptyDir,
    FileStat (..),
    fileStat,
    readFileStrict,
    uniqueTempPath,
) where

import qualified Control.Concurrent as Concurrent
import qualified Data.Char as Char
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable
import qualified System.IO as IO

-- The microhttp_fs.c wrappers: 0 on success, the syscall's errno on failure.
foreign import ccall "microhttp_fs.h mhfs_rename"
    c_rename :: CStr.CString -> CStr.CString -> IO CTypes.CLong
foreign import ccall "microhttp_fs.h mhfs_unlink" c_unlink :: CStr.CString -> IO CTypes.CLong
foreign import ccall "microhttp_fs.h mhfs_rmdir" c_rmdir :: CStr.CString -> IO CTypes.CLong
foreign import ccall "microhttp_fs.h mhfs_stat"
    c_stat :: CStr.CString -> Ptr.Ptr () -> IO CTypes.CLong

-- | A failed syscall's @errno@ (e.g. @2@ = ENOENT, @13@ = EACCES, macOS @66@ = ENOTEMPTY).
newtype Errno = Errno Int
    deriving (Eq, Show)

{- | Whether the errno is ENOENT: the path does not exist. The distinction
callers care about most -- a vanished file is usually expected (a delete or a
race), where any other errno (EACCES, EIO, ...) is a real fault worth logging.
POSIX fixes ENOENT at @2@ on every platform.
-}
isDoesNotExist :: Errno -> Bool
isDoesNotExist (Errno e) = e == 2

-- | Interprets a wrapper's return value: @0@ is success, anything else the errno.
outcome :: CTypes.CLong -> Either Errno ()
outcome 0 = Right ()
outcome e = Left (Errno (fromIntegral e))

-- | A file's modification time (sub-second) and size: the link index's freshness fingerprint (RFC-0029).
data FileStat = FileStat
    { fsMtimeSec :: Int
    , fsMtimeNsec :: Int
    , fsSize :: Int
    }
    deriving (Eq, Show)

-- macOS @struct stat@ layout (arm64/x86_64, 64-bit inode): the buffer size and the
-- byte offsets of st_mtimespec.tv_sec, its tv_nsec, and st_size. Platform-specific;
-- the portability RFC parameterises these (ADR-0067).

-- | The macOS @struct stat@ buffer size (bytes) to allocate for @stat(2)@ (ADR-0067).
statBufBytes :: Int
statBufBytes = 144

-- | Byte offset of @st_mtimespec.tv_sec@ within the macOS @struct stat@ (ADR-0067).
mtimeSecOffset :: Int
mtimeSecOffset = 48

-- | Byte offset of @st_mtimespec.tv_nsec@ within the macOS @struct stat@ (ADR-0067).
mtimeNsecOffset :: Int
mtimeNsecOffset = 56

-- | Byte offset of @st_size@ within the macOS @struct stat@ (ADR-0067).
sizeOffset :: Int
sizeOffset = 96

-- | Renames a file or directory (@rename(2)@); 'Left' carries the errno.
renamePath :: FilePath -> FilePath -> IO (Either Errno ())
renamePath from to =
    CStr.withCString from $ \f ->
        CStr.withCString to $ \t ->
            fmap outcome (c_rename f t)

-- | Removes a file (@unlink(2)@); 'Left' carries the errno.
removeFilePath :: FilePath -> IO (Either Errno ())
removeFilePath path = CStr.withCString path (fmap outcome . c_unlink)

-- | Removes an empty directory (@rmdir(2)@); 'Left' carries the errno.
removeEmptyDir :: FilePath -> IO (Either Errno ())
removeEmptyDir path = CStr.withCString path (fmap outcome . c_rmdir)

{- | The file's modification time and size via @stat(2)@, or the errno when the call
fails ('Errno' @2@, ENOENT, when the path is absent). The @mtime@ is sub-second
(macOS @st_mtimespec@), so an equal-length content edit -- swapping one link target
for another of the same length -- still moves it (RFC-0029, ADR-0067).
-}
fileStat :: FilePath -> IO (Either Errno FileStat)
fileStat path =
    CStr.withCString path $ \cpath ->
        Alloc.allocaBytes statBufBytes $ \buf -> do
            rc <- c_stat cpath buf
            case outcome rc of
                Left e -> pure (Left e)
                Right () -> do
                    sec <- Storable.peekByteOff buf mtimeSecOffset :: IO Int
                    nsec <- Storable.peekByteOff buf mtimeNsecOffset :: IO Int
                    size <- Storable.peekByteOff buf sizeOffset :: IO Int
                    pure (Right (FileStat sec nsec size))

{- | Reads a whole text file strictly: the content is fully forced before this
returns, so the handle is closed and the path can be rewritten immediately.
Prelude's lazy 'readFile' must not be used anywhere (STANDARDS.md): under GHC
it holds a read lock until the string is forced, so a later write to the same
path fails with @resource busy@ -- and mhs's does not, so the bug only shows in
GHC coverage builds. Text (UTF-8-decoded 'String') reads come through here;
binary content uses strict @Data.ByteString.Char8.readFile@ directly.
-}
readFileStrict :: FilePath -> IO String
readFileStrict path = do
    text <- readFile path -- whole-file: the strict-read primitive; each caller states its own bound
    length text `seq` pure text

{- | A path in @dir@ that no file currently occupies, for a temp-then-rename
write into that directory so the final rename never crosses a filesystem. The
file is not created: the caller opens it, and must do so before reserving the
same template again from the same thread, since only existing files and other
threads' names are excluded. Callers that need several at once use distinct
templates.

Deliberately not 'IO.openTempFile'. MicroHs's version probes each candidate by
opening it for reading and closing it, then opens the winner; done from one
connection thread while another connection is streaming, that open-and-close
stranded the other connection (RFC-0040 phase 3 baseline ref), and its probe is
not atomic across threads either. Here the name carries the calling thread's id,
so two threads can never contend for a candidate, and the probe is a @stat@.
-}
uniqueTempPath :: FilePath -> String -> IO FilePath
uniqueTempPath dir template = do
    tid <- Concurrent.myThreadId
    let prefix = dir ++ "/" ++ template ++ "-" ++ filter Char.isDigit (show tid) ++ "-"
        probe n = do
            let candidate = prefix ++ show (n :: Int)
            taken <- fileStat candidate
            case taken of
                Left _ -> pure candidate
                Right _ -> probe (n + 1)
    probe 0
