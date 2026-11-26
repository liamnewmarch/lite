#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/ttydefaults.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>
#include <libproc.h>
#include <string.h>

static void default_termios(struct termios *t) {
    // Same defaults the kernel uses, plus IUTF8 so canonical-mode line editing
    // (e.g. Backspace in `cat`) deletes whole UTF-8 characters.
    t->c_iflag = TTYDEF_IFLAG | IUTF8;
    t->c_oflag = TTYDEF_OFLAG;
    t->c_cflag = TTYDEF_CFLAG;
    t->c_lflag = TTYDEF_LFLAG;
    for (int i = 0; i < NCCS; i++) t->c_cc[i] = _POSIX_VDISABLE;
    t->c_cc[VEOF] = CEOF;
    t->c_cc[VEOL] = CEOL;
    t->c_cc[VEOL2] = CEOL;
    t->c_cc[VERASE] = CERASE;
    t->c_cc[VWERASE] = CWERASE;
    t->c_cc[VKILL] = CKILL;
    t->c_cc[VREPRINT] = CREPRINT;
    t->c_cc[VINTR] = CINTR;
    t->c_cc[VQUIT] = CQUIT;
    t->c_cc[VSUSP] = CSUSP;
    t->c_cc[VDSUSP] = CDSUSP;
    t->c_cc[VSTART] = CSTART;
    t->c_cc[VSTOP] = CSTOP;
    t->c_cc[VLNEXT] = CLNEXT;
    t->c_cc[VDISCARD] = CDISCARD;
    t->c_cc[VSTATUS] = CSTATUS;
    t->c_cc[VMIN] = CMIN;
    t->c_cc[VTIME] = CTIME;
    cfsetspeed(t, TTYDEF_SPEED);
}

int lite_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                   unsigned short rows, unsigned short cols,
                   unsigned short xpixel, unsigned short ypixel,
                   pid_t *out_pid) {
    struct termios term;
    default_termios(&term);
    struct winsize ws = { .ws_row = rows, .ws_col = cols, .ws_xpixel = xpixel, .ws_ypixel = ypixel };

    int master = -1;
    // forkpty = openpty + fork + (in child) setsid, TIOCSCTTY, dup2 slave onto 0/1/2.
    pid_t pid = forkpty(&master, NULL, &term, &ws);
    if (pid < 0) return -1;

    if (pid == 0) {
        // --- Child: async-signal-safe calls only from here to execve. ---

        // Undo anything inherited from the app: blocked signals (Dispatch threads
        // block some) and ignored signals (we ignore SIGPIPE), which survive exec.
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        struct sigaction dfl = { .sa_handler = SIG_DFL };
        sigemptyset(&dfl.sa_mask);
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig != SIGKILL && sig != SIGSTOP) sigaction(sig, &dfl, NULL);
        }

        // Don't leak the app's fds (Metal, windows server, other PTYs) to the shell.
        long max_fd = sysconf(_SC_OPEN_MAX);
        if (max_fd < 0 || max_fd > 4096) max_fd = 4096;
        for (int fd = 3; fd < max_fd; fd++) close(fd);

        if (cwd) (void)chdir(cwd);
        execve(path, argv, envp);
        _exit(127);
    }

    // --- Parent ---
    fcntl(master, F_SETFD, FD_CLOEXEC); // don't leak into later spawns
    *out_pid = pid;
    return master;
}

int lite_pty_set_size(int fd, unsigned short rows, unsigned short cols,
                      unsigned short xpixel, unsigned short ypixel) {
    struct winsize ws = { .ws_row = rows, .ws_col = cols, .ws_xpixel = xpixel, .ws_ypixel = ypixel };
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int lite_pty_wait_exit(pid_t pid) {
    siginfo_t info;
    int r;
    do { r = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT); } while (r < 0 && errno == EINTR);
    return r;
}

int lite_pty_reap(pid_t pid, int *exit_code) {
    int status = 0;
    pid_t r;
    do { r = waitpid(pid, &status, 0); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    if (WIFEXITED(status)) *exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) *exit_code = 128 + WTERMSIG(status);
    else *exit_code = -1;
    return 0;
}

pid_t lite_pty_foreground_pgid(int fd) {
    return tcgetpgrp(fd);
}

int lite_proc_cwd(pid_t pid, char *buf, int size) {
    struct proc_vnodepathinfo info;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (n != (int)sizeof(info) || size <= 0) return -1;
    strlcpy(buf, info.pvi_cdir.vip_path, (size_t)size);
    return 0;
}

int lite_proc_name(pid_t pid, char *buf, int size) {
    if (size <= 0) return -1;
    return proc_name(pid, buf, (uint32_t)size) > 0 ? 0 : -1;
}
