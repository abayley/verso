{- | The server's filesystem primitives for in-server move and delete (RFC-0027) and
the link index (RFC-0029): @rename(2)@, @unlink(2)@, @rmdir(2)@, and @stat(2)@ bound
directly via the C library, because MicroHs's @System.Directory@ has no atomic file
rename/remove and no modification time (the same libc escape hatch 'MicroHttp.Log'
uses for rotation, now consolidated here).

Unlike 'MicroHttp.Log', the mutation wrappers __check the return code__: each returns
'True' only when the syscall reported success (@0@), so a failed move or remove
surfaces to the caller rather than silently leaving the tree inconsistent (the
RFC-0027 reliability contract, ADR-061). 'fileStat' likewise returns 'Nothing' on a
non-zero return.

The path arguments are already-resolved filesystem paths; callers validate
tree-relative inputs with 'MicroHttp.Static.safeComponent' (via
@resolveStaticPath@) __before__ calling here, so these primitives perform no path
validation of their own.

The 'fileStat' field offsets are __macOS-specific__ (the @struct stat@ layout is
platform-dependent). They are isolated behind named constants so the cross-platform
portability RFC can parameterise them; ADR-067.
-}
module MicroHttp.FileSystem (
    renamePath,
    removeFilePath,
    removeEmptyDir,
    FileStat (..),
    fileStat,
) where

import qualified Foreign.C.String as CStr
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable

-- rename(2)/unlink(2)/rmdir(2) directly: MicroHs has no atomic renameFile/removeFile
-- in System.Directory, and exposes no removeDirectory either, so the filesystem
-- mutations drive libc. The return code (0 success, -1 error) is reported, unlike
-- MicroHttp.Log's best-effort rotation which discards it (ADR-061).
foreign import ccall "stdio.h rename" c_rename :: CStr.CString -> CStr.CString -> IO Int
foreign import ccall "unistd.h unlink" c_unlink :: CStr.CString -> IO Int
foreign import ccall "unistd.h rmdir" c_rmdir :: CStr.CString -> IO Int

-- stat(2) directly: MicroHs's System.Directory has no getModificationTime, and
-- fileSizeBytes cheats with lseek. On arm64/x86_64 macOS (64-bit inode) the plain
-- `stat` symbol is the modern struct; the fields the link index reads are at fixed
-- byte offsets (see the constants below). macOS-specific (ADR-067, RFC-0029).
foreign import ccall "sys/stat.h stat" c_stat :: CStr.CString -> Ptr.Ptr () -> IO Int

-- | A file's modification time (sub-second) and size: the link index's freshness fingerprint (RFC-0029).
data FileStat = FileStat
    { fsMtimeSec :: Int
    , fsMtimeNsec :: Int
    , fsSize :: Int
    }
    deriving (Eq, Show)

-- macOS @struct stat@ layout (arm64/x86_64, 64-bit inode): the buffer size and the
-- byte offsets of st_mtimespec.tv_sec, its tv_nsec, and st_size. Platform-specific;
-- the portability RFC parameterises these (ADR-067).

-- | The macOS @struct stat@ buffer size (bytes) to allocate for @stat(2)@ (ADR-067).
statBufBytes :: Int
statBufBytes = 144

-- | Byte offset of @st_mtimespec.tv_sec@ within the macOS @struct stat@ (ADR-067).
mtimeSecOffset :: Int
mtimeSecOffset = 48

-- | Byte offset of @st_mtimespec.tv_nsec@ within the macOS @struct stat@ (ADR-067).
mtimeNsecOffset :: Int
mtimeNsecOffset = 56

-- | Byte offset of @st_size@ within the macOS @struct stat@ (ADR-067).
sizeOffset :: Int
sizeOffset = 96

-- | Renames a file or directory, returning 'True' on success (@rename(2)@ == 0).
renamePath :: FilePath -> FilePath -> IO Bool
renamePath from to =
    CStr.withCString from $ \f ->
        CStr.withCString to $ \t ->
            fmap (== 0) (c_rename f t)

-- | Removes a file, returning 'True' on success (@unlink(2)@ == 0).
removeFilePath :: FilePath -> IO Bool
removeFilePath path = CStr.withCString path (fmap (== 0) . c_unlink)

-- | Removes an empty directory, returning 'True' on success (@rmdir(2)@ == 0).
removeEmptyDir :: FilePath -> IO Bool
removeEmptyDir path = CStr.withCString path (fmap (== 0) . c_rmdir)

{- | The file's modification time and size via @stat(2)@, or 'Nothing' when the call
fails (the path is absent or unreadable). The @mtime@ is sub-second (macOS
@st_mtimespec@), so an equal-length content edit -- swapping one link target for
another of the same length -- still moves it (RFC-0029, ADR-067).
-}
fileStat :: FilePath -> IO (Maybe FileStat)
fileStat path =
    CStr.withCString path $ \cpath ->
        Alloc.allocaBytes statBufBytes $ \buf -> do
            rc <- c_stat cpath buf
            if rc /= 0
                then pure Nothing
                else do
                    sec <- Storable.peekByteOff buf mtimeSecOffset :: IO Int
                    nsec <- Storable.peekByteOff buf mtimeNsecOffset :: IO Int
                    size <- Storable.peekByteOff buf sizeOffset :: IO Int
                    pure (Just (FileStat sec nsec size))
