/* Filesystem syscall wrappers for MicroHttp.FileSystem: each returns 0 on
 * success and the syscall's errno on failure, folded into one return value
 * so the Haskell side never races another green thread's C call between
 * reading the return code and reading errno (any C call blocks the whole
 * MicroHs runtime, but two separate calls do not).
 */
#ifndef MICROHTTP_FS_H
#define MICROHTTP_FS_H

long mhfs_rename(const char *from, const char *to);
long mhfs_unlink(const char *path);
long mhfs_rmdir(const char *path);

/* stat(2) into a caller-allocated buffer (MicroHttp.FileSystem knows the
 * platform's struct stat size and field offsets; ADR-067). */
long mhfs_stat(const char *path, void *buf);

#endif
