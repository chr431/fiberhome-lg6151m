// nerepair.c -- ptrace supervisor: repair the 32B-record va_list fault, cover all user processes.
// Record family: {A,0,B,0} at the fault-time va_list (x2); fault = ldr Xt,[Xt] with si_addr == Xt.
// Repair: set Xt = sp (safe mapped pointer), skip the load (pc += 4), suppress the signal.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <stdarg.h>
#include <time.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <sys/types.h>

#ifndef __WALL
#define __WALL 0x40000000
#endif
#ifndef PTRACE_GETREGSET
#define PTRACE_GETREGSET 0x4204
#endif
#ifndef PTRACE_SETREGSET
#define PTRACE_SETREGSET 0x4205
#endif
#ifndef PTRACE_O_TRACEFORK
#define PTRACE_O_TRACEFORK 0x00000002
#define PTRACE_O_TRACEVFORK 0x00000004
#define PTRACE_O_TRACECLONE 0x00000008
#define PTRACE_O_TRACEEXEC 0x00000010
#endif
#define NT_PRSTATUS 1

struct regs64 { unsigned long regs[31]; unsigned long sp, pc, pstate; };
static pid_t self_pid;
static int logfd = -1;

static void logmsg(const char *fmt, ...) {
    char buf[512]; int n; va_list ap; time_t t; struct tm tm;
    time(&t); localtime_r(&t, &tm);
    n = snprintf(buf, sizeof buf, "%04d-%02d-%02d %02d:%02d:%02d ",
                 tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    va_start(ap, fmt); n += vsnprintf(buf+n, sizeof buf-n, fmt, ap); va_end(ap);
    if (n < (int)sizeof buf - 1) buf[n++] = '\n';
    if (logfd >= 0) { ssize_t r = write(logfd, buf, n); (void)r; }
}
static int read_mem(pid_t pid, unsigned long addr, void *buf, size_t len) {
    struct iovec l = { buf, len }, r = { (void*)addr, len };
    return process_vm_readv(pid, &l, 1, &r, 1, 0) == (ssize_t)len ? 0 : -1;
}
static int is_ldr_same(unsigned int insn, int *rt, int *rn) {
    if ((insn & 0xFFC00000) == 0xF9400000 || (insn & 0xFFC00000) == 0xB9400000 ||
        (insn & 0xFFE00C00) == 0xF8400000 || (insn & 0xFFE00C00) == 0xB8400000 ||
        (insn & 0xFFE00C00) == 0xF8600000 || (insn & 0xFFE00C00) == 0xB8600000 ||
        (insn & 0xFFC00000) == 0x39400000 || (insn & 0xFFC00000) == 0x79400000 ||
        (insn & 0xFFC00000) == 0xB9800000) {
        *rt = insn & 0x1F; *rn = (insn >> 5) & 0x1F; return 1;
    }
    return 0;
}
static int shape_ok(unsigned long *w, unsigned long fault) {
    unsigned long w0=w[0], w1=w[1], w2=w[2];
    int small0 = fault > 0 && fault < (1UL<<24);
    int small2 = w2 > 0 && w2 < (1UL<<24);
    int big0 = (fault >> 32) != 0 && (fault & 0xFFFFFFFFUL) != 0;
    int big2 = (w2 >> 32) != 0 && (w2 & 0xFFFFFFFFUL) != 0;
    if (w1 != 0) return 0;
    if (w0 != fault && w0 != fault + 8) return 0;
    if (small0 && big2) return 1;
    if (big0 && small2) return 1;
    return 0;
}
static int is_canary(pid_t pid) {
    char path[64], buf[64]; int fd, n;
    snprintf(path, sizeof path, "/proc/%d/comm", pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    n = read(fd, buf, sizeof buf - 1); close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    return strstr(buf, "vsurv4") != NULL;
}
static int handle_segv(pid_t pid) {
    if (is_canary(pid)) return 0;
    siginfo_t si; struct regs64 r; struct iovec iov; unsigned int insn; int rt, rn;
    unsigned long w[4];
    if (ptrace(PTRACE_GETSIGINFO, pid, 0, &si) < 0) return 0;
    iov.iov_base = &r; iov.iov_len = sizeof r;
    if (ptrace(PTRACE_GETREGSET, pid, NT_PRSTATUS, &iov) < 0) return 0;
    if (read_mem(pid, r.pc, &insn, 4) < 0) return 0;
    logmsg("segv pid=%d pc=%#lx addr=%#lx x2=%#lx x8=%#lx insn=%#x", pid, r.pc, (unsigned long)si.si_addr, r.regs[2], r.regs[8], insn);
    if (!is_ldr_same(insn, &rt, &rn)) { logmsg("  not-load"); return 0; }
    logmsg("  rt=%d rn=%d", rt, rn);
    if (rt != rn) return 0;
    if ((unsigned long)si.si_addr != r.regs[rt]) return 0;
    if (read_mem(pid, r.regs[2], w, 32) < 0) { logmsg("  x2-unreadable"); return 0; }
    logmsg("  w=%#lx %#lx %#lx %#lx", w[0], w[1], w[2], w[3]);
    if (!shape_ok(w, (unsigned long)si.si_addr)) { logmsg("  shape-fail"); return 0; }
    r.regs[rt] = r.sp;
    r.pc += 4;
    iov.iov_base = &r; iov.iov_len = sizeof r;
    if (ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, &iov) < 0) return 0;
    logmsg("repaired pid=%d pc=%#lx fault=%#lx rt=%d", pid, r.pc-4, (unsigned long)si.si_addr, rt);
    return 1;
}
static int traced(pid_t pid) {
    char path[64], buf[256]; int fd; ssize_t n; char *p;
    snprintf(path, sizeof path, "/proc/%d/status", pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) return 1;
    n = read(fd, buf, sizeof buf - 1); close(fd);
    if (n <= 0) return 1;
    buf[n] = 0;
    p = strstr(buf, "TracerPid:");
    if (!p) return 0;
    return atoi(p + 10) != 0;
}
static void attach_pid(pid_t pid) {
    int st;
    if (pid == self_pid || pid <= 0) return;
    if (ptrace(PTRACE_ATTACH, pid, 0, 0) < 0) return;
    if (waitpid(pid, &st, __WALL) < 0) return;
    ptrace(PTRACE_SETOPTIONS, pid, 0, PTRACE_O_TRACEFORK|PTRACE_O_TRACEVFORK|PTRACE_O_TRACECLONE|PTRACE_O_TRACEEXEC);
    ptrace(PTRACE_CONT, pid, 0, 0);
    logmsg("attached %d", pid);
}
static void scan_proc(void) {
    DIR *d = opendir("/proc"); struct dirent *de; pid_t p;
    if (!d) return;
    while ((de = readdir(d))) {
        if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
        p = atoi(de->d_name);
        if (p > 1 && !traced(p)) attach_pid(p);
    }
    closedir(d);
}
int main(void) {
    int st; pid_t pid;
    self_pid = getpid();
    logfd = open("/data/gw/logs/nerepair.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    logmsg("start pid=%d", self_pid);
    if (!traced(1)) attach_pid(1);
    scan_proc();
    for (;;) {
        pid = waitpid(-1, &st, __WALL);
        if (pid < 0) {
            if (errno == EINTR) continue;
            if (errno == ECHILD) { usleep(500000); scan_proc(); continue; }
            break;
        }
        if (!WIFSTOPPED(st)) continue;
        int sig = WSTOPSIG(st);
        int ev = st >> 16;
        if (ev) { ptrace(PTRACE_CONT, pid, 0, 0); continue; }
        if (sig == SIGSEGV || sig == SIGBUS) {
            if (handle_segv(pid)) { ptrace(PTRACE_CONT, pid, 0, 0); continue; }
            ptrace(PTRACE_CONT, pid, 0, sig);
            continue;
        }
        if (sig == SIGSTOP) { ptrace(PTRACE_CONT, pid, 0, SIGCONT); continue; }
        ptrace(PTRACE_CONT, pid, 0, sig);
    }
    logmsg("exit");
    return 0;
}
