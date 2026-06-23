{- | The server's filesystem-mutation primitives for in-server move and delete
(RFC-0027): @rename(2)@, @unlink(2)@, and @rmdir(2)@ bound directly via the C
library, because MicroHs's @System.Directory@ has no atomic file rename/remove (the
same libc escape hatch 'MicroHttp.Log' uses for rotation, now consolidated here).

Unlike 'MicroHttp.Log', these wrappers __check the return code__: each returns
'True' only when the syscall reported success (@0@), so a failed move or remove
surfaces to the caller rather than silently leaving the tree inconsistent (the
RFC-0027 reliability contract, ADR-061).

The path arguments are already-resolved filesystem paths; callers validate
tree-relative inputs with 'MicroHttp.Static.safeComponent' (via
@resolveStaticPath@) __before__ calling here, so these primitives perform no path
validation of their own.
-}
module MicroHttp.FileOps (
    renamePath,
    removeFilePath,
    removeEmptyDir,
) where

import Foreign.C.String (CString, withCString)

-- rename(2)/unlink(2)/rmdir(2) directly: MicroHs has no atomic renameFile/removeFile
-- in System.Directory, and exposes no removeDirectory either, so the filesystem
-- mutations drive libc. The return code (0 success, -1 error) is reported, unlike
-- MicroHttp.Log's best-effort rotation which discards it (ADR-061).
foreign import ccall "stdio.h rename" c_rename :: CString -> CString -> IO Int
foreign import ccall "unistd.h unlink" c_unlink :: CString -> IO Int
foreign import ccall "unistd.h rmdir" c_rmdir :: CString -> IO Int

-- | Renames a file or directory, returning 'True' on success (@rename(2)@ == 0).
renamePath :: FilePath -> FilePath -> IO Bool
renamePath from to =
    withCString from $ \f ->
        withCString to $ \t ->
            fmap (== 0) (c_rename f t)

-- | Removes a file, returning 'True' on success (@unlink(2)@ == 0).
removeFilePath :: FilePath -> IO Bool
removeFilePath path = withCString path (fmap (== 0) . c_unlink)

-- | Removes an empty directory, returning 'True' on success (@rmdir(2)@ == 0).
removeEmptyDir :: FilePath -> IO Bool
removeEmptyDir path = withCString path (fmap (== 0) . c_rmdir)
