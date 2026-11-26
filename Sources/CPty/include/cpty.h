#ifndef LITE_CPTY_H
#define LITE_CPTY_H

#include <sys/types.h>

/// Spawn `path` on a new pseudo-terminal.
///
/// Everything the child needs (argv, envp, cwd) must be prepared by the caller
/// *before* this call: between fork and exec the child may only use
/// async-signal-safe functions, which is why this lives in C rather than Swift.
///
/// Returns the master fd (blocking, close-on-exec) and stores the child pid in
/// `out_pid`, or returns -1 and sets errno.
int lite_pty_spawn(const char *path,
                   char *const argv[],
                   char *const envp[],
                   const char *cwd,
                   unsigned short rows, unsigned short cols,
                   unsigned short xpixel, unsigned short ypixel,
                   pid_t *out_pid);

/// TIOCSWINSZ on the master. The kernel sends SIGWINCH to the foreground job.
int lite_pty_set_size(int fd,
                      unsigned short rows, unsigned short cols,
                      unsigned short xpixel, unsigned short ypixel);

/// Blocks until `pid` has exited, *without* reaping it (the zombie keeps its pid
/// reserved, so it can't be reused yet). Returns 0, or -1 on error.
int lite_pty_wait_exit(pid_t pid);

/// Reaps an exited `pid` and stores a shell-style exit code (the status, or
/// 128 + signal). Returns 0, or -1 on error.
/// (WIFEXITED & co. are macros Swift can't import.)
int lite_pty_reap(pid_t pid, int *exit_code);

/// Process group in the foreground of the terminal (e.g. vim while it runs,
/// otherwise the shell), or -1.
pid_t lite_pty_foreground_pgid(int fd);

/// Current working directory of `pid` into `buf`. Returns 0, or -1.
/// Works for our own children without special entitlements.
int lite_proc_cwd(pid_t pid, char *buf, int size);

/// Short name of `pid`'s executable (e.g. "vim") into `buf`. Returns 0, or -1.
int lite_proc_name(pid_t pid, char *buf, int size);

#endif
