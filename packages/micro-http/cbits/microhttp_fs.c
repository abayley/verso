#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "microhttp_fs.h"

long mhfs_rename(const char *from, const char *to) {
    return rename(from, to) == 0 ? 0 : (long) errno;
}

long mhfs_unlink(const char *path) {
    return unlink(path) == 0 ? 0 : (long) errno;
}

long mhfs_rmdir(const char *path) {
    return rmdir(path) == 0 ? 0 : (long) errno;
}

long mhfs_stat(const char *path, void *buf) {
    return stat(path, (struct stat *) buf) == 0 ? 0 : (long) errno;
}

long mhfs_set_nonblock(long fd) {
    int flags = fcntl((int) fd, F_GETFL, 0);
    if (flags < 0) {
        return (long) errno;
    }
    return fcntl((int) fd, F_SETFL, flags | O_NONBLOCK) == 0 ? 0 : (long) errno;
}
