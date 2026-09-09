/* Subprocess spawner for MicroHttp.Process, built on posix_spawnp(3).
 *
 * The server hosts native thread pools (LanceDB's tokio runtime, ONNX
 * workers) whose threads do not survive fork(2): a forked child that runs
 * any user code before exec can resume a green thread whose next step is a
 * blocking call into one of those pools and deadlock (or abort) waiting on
 * workers that no longer exist. posix_spawn goes straight to exec without
 * running user code in the child, so the hazard cannot arise.
 *
 * The posix_spawn_file_actions_t type is opaque with a platform-dependent
 * size, so the whole spawn - file actions, chdir, exec - lives behind this
 * one C call. Returns the child pid (> 0) on success or the negated errno
 * (< 0) on failure, folded into one return value so the Haskell side never
 * races another green thread's C call between the call and reading errno.
 */
#ifndef MICROHTTP_PROCESS_H
#define MICROHTTP_PROCESS_H

/* Spawns exe (resolved via PATH) with the NULL-terminated argv, stdout and
 * stderr redirected to the already-open out_fd/err_fd, stdin redirected to
 * in_fd when >= 0 (inherited otherwise), chdir'ing to cwd first when cwd is
 * non-NULL. The passed fds stay open in the parent (close them there). */
long mhp_spawn(const char *exe, char *const argv[], const char *cwd,
               long out_fd, long err_fd, long in_fd);

#endif
