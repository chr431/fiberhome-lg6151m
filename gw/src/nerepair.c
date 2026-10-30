/*
 * nerepair.c v1.4 -- ptrace supervisor: repair the 32B-record va_list fault
 * in place, cover every user process on the device.
 *
 * Role in the SIGSEGV fix (docs/SIGSEGV/FIX.md): vaguard protects the static
 * binaries we build; nerepair is the runtime safety net for everything else
 * (vendor binaries, ash/awk/grep CGI chains).  It attaches to all pids, and
 * on each SIGSEGV/SIGBUS stop decides whether the fault matches the known
 * va_list corruption shape; if it does, the faulting load is skipped and the
 * destination register is pointed at the stack so the callee survives.  The
 * vsurv4 canary is always passed through so the fix stays measurable.
 *
 * Event log: /data/gw/logs/nerepair.log, TSV
 *   epoch  iso8601  pid  comm  event  detail
 * 1MB rotation (single .1 generation), 20 lines/s rate limit, 60s STAT
 * heartbeat, heartbeat file /tmp/nerepair.hb (uptime seconds, for the
 * watchdog SVC_TABLE liveness probe).
 *
 * v1.4 (code-quality round):
 *   - attach_pid: waitpid is now retried on EINTR and PTRACE_DETACHes on any
 *     other failure.  Since v13 SIGALRM deliberately lacks SA_RESTART, an
 *     alarm landing inside attach could abort the wait and leave the tracee
 *     in group-stop forever (attaching to dropbear would freeze SSH).
 *   - logev: snprintf return values are clamped before advancing the write
 *     cursor (snprintf returns the *would-be* length; the old accounting
 *     could index past msg[] if a format string ever grew past the buffer).
 *   - main: the SIGTERM sigaction no longer shadows the wait status `st`.
 *   - version string centralized in NEREPAIR_VER (START record), comment
 *     style aligned with the rest of gw/src.
 * v1.3: SIGALRM handler installed without SA_RESTART so waitpid returns
 *   EINTR and the heartbeat/STAT ticks actually fire.
 * v1.2: /tmp/nerepair.hb heartbeat (60s) for watchdog svc_supervise.
 * v1.1: structured TSV log + 1MB rotation + 20 lines/s rate limit + 60s
 *   STAT + SIGTERM/SIGINT EXIT record.
 * v1.0: repair core (is_ldr_same/shape_ok/register rewrite).
 *
 * Build: sh tools/build_nerepair.sh   (zig cc aarch64-linux-musl, static,
 * vaguard linked like every other static binary -- see FIX.md §"保持现状".)
 */
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
#include <sys/stat.h>
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
#define LOGPATH "/data/gw/logs/nerepair.log"
#define NEREPAIR_VER "1.4"

struct regs64 { unsigned long regs[31]; unsigned long sp, pc, pstate; };
static pid_t self_pid;
static int logfd = -1;
static unsigned long g_attached, g_segv, g_repaired, g_passed, g_suppressed;
static time_t g_rate_win;
static int g_rate_cnt;
static volatile sig_atomic_t g_alarm, g_term;

static void comm_of(pid_t pid, char *out, size_t n)
{
    char path[64]; int fd; ssize_t r; char *p;
    snprintf(path, sizeof path, "/proc/%d/comm", pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) { snprintf(out, n, "?"); return; }
    r = read(fd, out, n - 1); close(fd);
    if (r <= 0) { snprintf(out, n, "?"); return; }
    out[r] = 0;
    p = strchr(out, '\n'); if (p) *p = 0;
}
static void rotate_log(void)
{
    struct stat st;
    if (logfd < 0) return;
    if (fstat(logfd, &st) == 0 && st.st_size > 1024 * 1024) {
        close(logfd);
        rename(LOGPATH, LOGPATH ".1");
        logfd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
}
static int rate_ok(void)
{
    time_t now = time(NULL);
    if (now != g_rate_win) { g_rate_win = now; g_rate_cnt = 0; }
    if (g_rate_cnt >= 20) { g_suppressed++; return 0; }
    g_rate_cnt++;
    return 1;
}
static void logev(const char *ev, pid_t pid, const char *fmt, ...)
{
    char msg[512]; char comm[32]; int n, m; va_list ap; time_t t; struct tm tm;
    time(&t); localtime_r(&t, &tm);
    comm_of(pid, comm, sizeof comm);
    n = snprintf(msg, sizeof msg, "%ld\t%04d-%02d-%02dT%02d:%02d:%02d\t%d\t%s\t%s",
                 (long)t, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                 tm.tm_hour, tm.tm_min, tm.tm_sec, (int)pid, comm, ev);
    if (n < 0) return;
    if (n > (int)sizeof msg - 2) n = (int)sizeof msg - 2;   /* clamp: would-be length */
    msg[n++] = '\t';
    va_start(ap, fmt);
    m = vsnprintf(msg + n, sizeof msg - n, fmt, ap);
    va_end(ap);
    if (m < 0) m = 0;
    if (m > (int)sizeof msg - 1 - n) m = (int)sizeof msg - 1 - n;
    n += m;
    msg[n++] = '\n';
    if (logfd >= 0) { ssize_t r = write(logfd, msg, n); (void)r; }
    rotate_log();
}
static int read_mem(pid_t pid, unsigned long addr, void *buf, size_t len)
{
    struct iovec l = { buf, len }, r = { (void *)addr, len };
    return process_vm_readv(pid, &l, 1, &r, 1, 0) == (ssize_t)len ? 0 : -1;
}
static int is_ldr_same(unsigned int insn, int *rt, int *rn)
{
    if ((insn & 0xFFC00000) == 0xF9400000 || (insn & 0xFFC00000) == 0xB9400000 ||
        (insn & 0xFFE00C00) == 0xF8400000 || (insn & 0xFFE00C00) == 0xB8400000 ||
        (insn & 0xFFE00C00) == 0xF8600000 || (insn & 0xFFE00C00) == 0xB8600000 ||
        (insn & 0xFFC00000) == 0x39400000 || (insn & 0xFFC00000) == 0x79400000 ||
        (insn & 0xFFC00000) == 0xB9800000) {
        *rt = insn & 0x1F; *rn = (insn >> 5) & 0x1F; return 1;
    }
    return 0;
}
static int shape_ok(unsigned long *w, unsigned long fault)
{
    unsigned long w0 = w[0], w1 = w[1], w2 = w[2];
    int small0 = fault > 0 && fault < (1UL << 24);
    int small2 = w2 > 0 && w2 < (1UL << 24);
    int big0 = (fault >> 32) != 0 && (fault & 0xFFFFFFFFUL) != 0;
    int big2 = (w2 >> 32) != 0 && (w2 & 0xFFFFFFFFUL) != 0;
    if (w1 != 0) return 0;
    if (w0 != fault && w0 != fault + 8) return 0;
    if (small0 && big2) return 1;
    if (big0 && small2) return 1;
    return 0;
}
static int is_canary(pid_t pid)
{
    char comm[32];
    comm_of(pid, comm, sizeof comm);
    return strstr(comm, "vsurv4") != NULL;
}
static int handle_segv(pid_t pid)
{
    siginfo_t si; struct regs64 r; struct iovec iov; unsigned int insn; int rt, rn;
    unsigned long w[4];
    if (is_canary(pid)) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=canary"); return 0; }
    if (ptrace(PTRACE_GETSIGINFO, pid, 0, &si) < 0) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=getsiginfo"); return 0; }
    iov.iov_base = &r; iov.iov_len = sizeof r;
    if (ptrace(PTRACE_GETREGSET, pid, NT_PRSTATUS, &iov) < 0) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=getregs"); return 0; }
    if (read_mem(pid, r.pc, &insn, 4) < 0) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=pc-unreadable"); return 0; }
    g_segv++;
    if (rate_ok()) logev("SEGV", pid, "pc=%#lx addr=%#lx x2=%#lx x8=%#lx insn=%#x", r.pc, (unsigned long)si.si_addr, r.regs[2], r.regs[8], insn);
    if (!is_ldr_same(insn, &rt, &rn)) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=not-load"); return 0; }
    if (rt != rn) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=rt-ne-rn rt=%d rn=%d", rt, rn); return 0; }
    if ((unsigned long)si.si_addr != r.regs[rt]) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=addr-ne-xt"); return 0; }
    if (read_mem(pid, r.regs[2], w, 32) < 0) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=x2-unreadable"); return 0; }
    if (!shape_ok(w, (unsigned long)si.si_addr)) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=shape-fail w=%#lx,%#lx,%#lx,%#lx", w[0], w[1], w[2], w[3]); return 0; }
    r.regs[rt] = r.sp;
    r.pc += 4;
    iov.iov_base = &r; iov.iov_len = sizeof r;
    if (ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, &iov) < 0) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=setregs"); return 0; }
    g_repaired++;
    if (rate_ok()) logev("REPAIR", pid, "pc=%#lx fault=%#lx rt=%d", r.pc - 4, (unsigned long)si.si_addr, rt);
    return 1;
}
static int traced(pid_t pid)
{
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
static void attach_pid(pid_t pid)
{
    int st; pid_t w;
    if (pid == self_pid || pid <= 0) return;
    if (ptrace(PTRACE_ATTACH, pid, 0, 0) < 0) return;
    /* v1.4: EINTR-retry (SIGALRM has no SA_RESTART since v1.3) and detach on
     * any other wait failure -- a tracee abandoned in group-stop is frozen
     * for good (PTRACE_DETACH on a dead/non-stopped pid just fails softly). */
    do { w = waitpid(pid, &st, __WALL); } while (w < 0 && errno == EINTR);
    if (w < 0 || !WIFSTOPPED(st)) { ptrace(PTRACE_DETACH, pid, 0, 0); return; }
    ptrace(PTRACE_SETOPTIONS, pid, 0, PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE | PTRACE_O_TRACEEXEC);
    ptrace(PTRACE_CONT, pid, 0, 0);
    g_attached++;
    logev("ATTACH", pid, "total=%lu", g_attached);
}
static void scan_proc(void)
{
    DIR *d = opendir("/proc"); struct dirent *de; pid_t p;
    if (!d) return;
    while ((de = readdir(d))) {
        if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
        p = atoi(de->d_name);
        if (p > 1 && !traced(p)) attach_pid(p);
    }
    closedir(d);
}
static void write_hb(void)
{
    int fd, n; char b[32]; unsigned long up = 0;
    fd = open("/proc/uptime", O_RDONLY);
    if (fd >= 0) { n = read(fd, b, sizeof b - 1); close(fd); if (n > 0) { b[n] = 0; up = strtoul(b, NULL, 10); } }
    fd = open("/tmp/nerepair.hb", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { n = snprintf(b, sizeof b, "%lu", up); b[n++] = 10; if (write(fd, b, n) < 0) {} close(fd); }
}
static void on_alarm(int s) { (void)s; g_alarm = 1; }
static void on_term(int s) { (void)s; g_term = 1; }
int main(void)
{
    int st; pid_t pid;
    self_pid = getpid();
    logfd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    logev("START", 0, "pid=%d ver=%s", self_pid, NEREPAIR_VER);
    write_hb();
    { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_alarm; sa.sa_flags = 0; sigaction(SIGALRM, &sa, NULL); }
    { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_term; sa.sa_flags = 0; sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); }
    alarm(60);
    if (!traced(1)) attach_pid(1);
    scan_proc();
    logev("SCAN", 0, "attached_total=%lu", g_attached);
    for (;;) {
        if (g_term) {
            logev("EXIT", 0, "signal attached=%lu segv=%lu repaired=%lu passed=%lu suppressed=%lu",
                  g_attached, g_segv, g_repaired, g_passed, g_suppressed);
            return 0;
        }
        pid = waitpid(-1, &st, __WALL);
        if (pid < 0) {
            if (errno == EINTR) {
                if (g_alarm) {
                    g_alarm = 0; alarm(60); write_hb();
                    logev("STAT", 0, "attached=%lu segv=%lu repaired=%lu passed=%lu suppressed=%lu",
                          g_attached, g_segv, g_repaired, g_passed, g_suppressed);
                }
                continue;
            }
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
    logev("EXIT", 0, "loop attached=%lu segv=%lu repaired=%lu passed=%lu suppressed=%lu",
          g_attached, g_segv, g_repaired, g_passed, g_suppressed);
    return 0;
}
