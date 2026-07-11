/* posix_spawn_file_actions_addchdir_np needs _GNU_SOURCE on glibc; harmless
 * on macOS, where the function is available from 10.15. */
#define _GNU_SOURCE

#include "microhttp_process.h"

#include <errno.h>
#include <spawn.h>
#include <sys/types.h>

extern char **environ;

long mhp_spawn(const char *exe, char *const argv[], const char *cwd,
               long out_fd, long err_fd, long in_fd)
{
    posix_spawn_file_actions_t actions;
    pid_t pid;
    int rc;

    rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0)
        return -(long)rc;

    if (cwd != NULL)
        rc = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    if (rc == 0)
        rc = posix_spawn_file_actions_adddup2(&actions, (int)out_fd, 1);
    if (rc == 0)
        rc = posix_spawn_file_actions_adddup2(&actions, (int)err_fd, 2);
    if (rc == 0 && in_fd >= 0)
        rc = posix_spawn_file_actions_adddup2(&actions, (int)in_fd, 0);
    /* Close the capture fds in the child once duplicated onto stdio, so the
     * spawned program holds no stray descriptors. */
    if (rc == 0 && out_fd > 2)
        rc = posix_spawn_file_actions_addclose(&actions, (int)out_fd);
    if (rc == 0 && err_fd > 2 && err_fd != out_fd)
        rc = posix_spawn_file_actions_addclose(&actions, (int)err_fd);
    if (rc == 0 && in_fd > 2 && in_fd != out_fd && in_fd != err_fd)
        rc = posix_spawn_file_actions_addclose(&actions, (int)in_fd);

    if (rc == 0)
        rc = posix_spawnp(&pid, exe, &actions, NULL, argv, environ);

    posix_spawn_file_actions_destroy(&actions);
    return rc == 0 ? (long)pid : -(long)rc;
}
