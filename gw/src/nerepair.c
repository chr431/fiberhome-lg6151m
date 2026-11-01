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
 * v1.7 (patrol round 2): heartbeat starvation fix -- g_alarm is now consumed
 *   at the top of the main loop instead of only in the waitpid-EINTR branch;
 *   a tracee event storm (constant fork/exec/signal stops) kept waitpid from
 *   ever blocking, so the flag was set but never serviced and the heartbeat
 *   starved for minutes (field: five 284-651s gaps, two watchdog restarts).
 * v1.6 (vaguard retirement round): single-layer doctrine -- the in-process
 *   vfprintf guard is retired everywhere (source of the fault family is gone
 *   since the kernel fixstack retirement; guard historically caught 49 hits).
 *   nerepair is now the only defense; this build links no guard and depends
 *   on nothing outside the repo.
 * v1.5 (patrol round): attach wait bounded to 3s (WNOHANG poll + deadline,
 *   detach on timeout) -- an un-stoppable tracee could block the v1.4 retry
 *   loop forever, freezing the supervisor (07:05-07:08 field incident:
 *   heartbeat silent 234s, watchdog restart).  Supervisor liveness beats
 *   per-pid coverage.
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
 * Build: sh tools/build_nerepair.sh   (zig cc aarch64-linux-musl, static;
 * v1.6 起 vaguard 退役, 本进程是唯一防线, 零闸门零仓外依赖 —— FIX.md §单层)
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
#define NEREPAIR_VER "2.0"

struct regs64 { unsigned long regs[31]; unsigned long sp, pc, pstate; };
static pid_t self_pid;
static int logfd = -1;
static unsigned long g_attached, g_segv, g_repaired, g_passed, g_suppressed, g_abuse;
static unsigned long g_would, g_near, g_loop, g_near_insn;
/* v2.0 counters: dereference-type path (see deref_attempt) */
static unsigned long g_rep2, g_would2, g_deref_scan, g_deref_hit;
static time_t g_rate_win;
static int g_rate_cnt;
/* v1.9: dry-run.  Enabled by env NEREPAIR_DRY=1, by the marker file
 * /data/gw/nerepair.dry, or by SIGUSR1 at runtime (toggle, logged as MODE).
 * In dry-run NOTHING is repaired and NO signal is swallowed: a matching fault is
 * logged as WOULD_REPAIR and the process dies exactly as it would without us. */
static volatile sig_atomic_t g_dry;
static volatile sig_atomic_t g_usr1;

/* v1.8/v1.9: repair-loop breaker, keyed on (tracee, faulting site).
 * A faulting load inside a loop would otherwise be "repaired" forever
 * (pc += 4 -> next iteration -> same load), turning a crash into a CPU-burning
 * livelock with a log storm.  Counting is per (pid, pc) and *consecutive*: a
 * different faulting site from the same tracee resets the counter.  After
 * NR_LOOP_MAX consecutive repairs at the same site the pair is marked dead for
 * the rest of its life and every later fault there is passed through untouched
 * (the tracee then dies normally). */
#define BRK_N 128
#define NR_LOOP_MAX 8
static struct { pid_t pid; unsigned long pc; int n; int dead; } g_brk[BRK_N];

/* returns 1 = repair allowed; *n = consecutive count at that site */
static int breaker_allow(pid_t pid, unsigned long pc, int *n)
{
    int i, slot = -1;

    for (i = 0; i < BRK_N; i++) {
        if (g_brk[i].pid == pid) { slot = i; break; }
        if (slot < 0 && g_brk[i].pid == 0) slot = i;
    }
    if (slot < 0) slot = (int)((unsigned)(pid * 2654435761u ^ (unsigned long)pc) % BRK_N);
    if (g_brk[slot].pid != pid || g_brk[slot].pc != pc) {
        g_brk[slot].pid = pid;
        g_brk[slot].pc = pc;
        g_brk[slot].n = 1;
        g_brk[slot].dead = 0;
    } else {
        g_brk[slot].n++;
    }
    *n = g_brk[slot].n;
    if (g_brk[slot].n > NR_LOOP_MAX)
        g_brk[slot].dead = 1;
    return !g_brk[slot].dead;
}

/* v1.8: REPAIR lines get their own budget.  The v1.7 single 20 lines/s budget was
 * shared with PASS/SEGV lines, so a crash storm (or the canary at 2/s) could
 * suppress the very lines that document what was repaired. */
static int rate_ok_prio(void)
{
    static time_t w; static int c;
    time_t now = time(NULL);
    if (now != w) { w = now; c = 0; }
    if (c >= 200) { g_suppressed++; return 0; }
    c++;
    return 1;
}
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
/* v1.9.1: BIN line -- resolve each tracee's executable ONCE (path + dev/ino) and
 * log it.  Why: the 'pc' in WOULD_REPAIR/NEAR/REPAIR is a *user-space* PC, so an
 * offline pass can only turn it into a function name if it knows which binary the
 * process was running.  The pid is gone by the time anyone reads the log, so the
 * mapping has to be recorded while the process is alive.  Cached by pid: one
 * readlink+stat per process, no cost on the hot path. */
#define BIN_N 256
static struct { pid_t pid; unsigned char seen; } g_bin[BIN_N];
static int bin_seen(pid_t pid)
{
    int i, slot = -1;

    for (i = 0; i < BIN_N; i++) {
        if (g_bin[i].seen && g_bin[i].pid == pid) return 1;
        if (slot < 0 && !g_bin[i].seen) slot = i;
    }
    if (slot < 0) slot = (int)((unsigned)pid % BIN_N);
    g_bin[slot].pid = pid;
    g_bin[slot].seen = 1;
    return 0;
}
static void note_bin(pid_t pid)
{
    char path[64], buf[256];
    ssize_t r;
    struct stat st;

    if (bin_seen(pid)) return;
    snprintf(path, sizeof path, "/proc/%d/exe", pid);
    r = readlink(path, buf, sizeof buf - 1);
    if (r <= 0) { if (rate_ok()) logev("BIN", pid, "path=? err=readlink"); return; }
    buf[r] = 0;
    if (stat(path, &st) != 0) { if (rate_ok()) logev("BIN", pid, "path=%s err=stat", buf); return; }
    if (rate_ok()) logev("BIN", pid, "path=%s dev=%lu ino=%lu", buf, (unsigned long)st.st_dev, (unsigned long)st.st_ino);
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
/* v1.8 hardening (host-verified by _local/work/crash-root/fix/nerepair_mask_test.c:
 * 150/150 real records still accepted; 8/8 synthetic non-family negatives now
 * rejected, of which v1.7 wrongly accepted 3):
 *   + w3 must be 0            (150/150 field samples: w1==0 and w3==0)
 *   + length band 0x400..0x20000 on the len word of whichever form matched
 *     (A0B2: lo32(w2); B0A2: lo32(w0); observed real lens 1601/1664/57497..72085)
 *   + TBI/MTE tag byte masked off before comparing w0 with the fault address
 * Rationale: a loose mask repairs crashes that are NOT this family -- it hides a
 * real defect and leaves the process running on garbage.  A missed repair only
 * restores the pre-nerepair behaviour: the process dies exactly as before. */
#define NR_TAGMASK 0x00FFFFFFFFFFFFFFUL
#define NR_LEN_MIN 0x400UL
#define NR_LEN_MAX 0x20000UL

static int shape_ok(unsigned long *w, unsigned long fault)
{
    unsigned long f = fault & NR_TAGMASK;
    unsigned long w0 = w[0] & NR_TAGMASK;
    unsigned long w1 = w[1], w2 = w[2], w3 = w[3];
    unsigned long lo0 = w[0] & 0xFFFFFFFFUL, lo2 = w[2] & 0xFFFFFFFFUL;
    int small0 = f > 0 && f < (1UL << 24);
    int small2 = w2 > 0 && w2 < (1UL << 24);
    int big0 = (f >> 32) != 0 && (f & 0xFFFFFFFFUL) != 0;
    int big2 = (w2 >> 32) != 0 && (w2 & 0xFFFFFFFFUL) != 0;

    if (w1 != 0 || w3 != 0) return 0;
    if (w0 != f && w0 != ((f + 8) & NR_TAGMASK)) return 0;
    if (small0 && big2) return lo2 >= NR_LEN_MIN && lo2 <= NR_LEN_MAX;
    if (big0 && small2) return lo0 >= NR_LEN_MIN && lo0 <= NR_LEN_MAX;
    return 0;
}
/* v1.9 canary exemption -- project 定律二 (exact token, never a substring).
 * The authoritative source is the *inode* of /proc/<pid>/exe, resolved once at
 * startup from NEREPAIR_CANARY (default /data/repro/vsurv4).  The exe path is
 * compared as a whole string first (catches the common case without a stat),
 * then dev/ino confirms it -- a rename, a copy, or a process merely *called*
 * vsurv4 does NOT get an exemption.  If the canary binary is absent, nobody is
 * exempt (fail-closed: we never trust a name we could not resolve). */
static char g_can_path[128];
static dev_t g_can_dev;
static ino_t g_can_ino;
static int g_can_ok;

static void canary_init(void)
{
    struct stat st;
    const char *p = getenv("NEREPAIR_CANARY");

    snprintf(g_can_path, sizeof g_can_path, "%s", p && *p ? p : "/data/repro/vsurv4");
    if (stat(g_can_path, &st) == 0 && S_ISREG(st.st_mode)) {
        g_can_dev = st.st_dev;
        g_can_ino = st.st_ino;
        g_can_ok = 1;
    }
}

static int is_canary(pid_t pid)
{
    char path[64], buf[256];
    size_t n;
    ssize_t r;
    struct stat st;

    if (!g_can_ok)
        return 0;
    snprintf(path, sizeof path, "/proc/%d/exe", pid);
    r = readlink(path, buf, sizeof buf - 1);
    if (r <= 0)
        return 0;
    buf[r] = 0;
    n = strlen(g_can_path);
    if (strncmp(buf, g_can_path, n) != 0)
        return 0;
    /* the kernel appends " (deleted)" to an unlinked exe; anything else is a
     * different path that merely shares a prefix -> not a match */
    if (buf[n] != 0 && strcmp(buf + n, " (deleted)") != 0)
        return 0;
    if (stat(path, &st) != 0)
        return 0;
    return st.st_dev == g_can_dev && st.st_ino == g_can_ino;
}
/* v1.9.2 -- OBSERVATION ONLY, no behaviour change.
 * When a fault matches none of the three geometric clauses (is it a register-
 * self-referential load? is rt==rn? is si_addr==Xt?), the family record may
 * still be sitting at x2: the same va_list corruption surfacing through a
 * DIFFERENT instruction shape -- e.g. the popped garbage value being dereferenced
 * inside strlen/memcpy (ldrb w2,[x0]), where rt != rn.  Those faults are still
 * passed through untouched; we only count them so a dry-run can size the blind
 * spot ("how much of the family is outside nerepair's reach").  Cost: one
 * process_vm_readv(32) per *rejected* fault, i.e. only after the cheap tests. */
static int record_probe(pid_t pid, struct regs64 *r, unsigned long fault)
{
    unsigned long w[4];

    if (read_mem(pid, r->regs[2], w, 32) < 0)
        return 0;
    return shape_ok(w, fault);
}

/* ------------------------------------------------------------------ v2.0 ----
 * The pop-type mask (A && B && C && D, see shape_ok/is_ldr_same) only catches the
 * instruction that *consumes* the va_list.  The same corruption far more often
 * surfaces one step later: the garbage value is used as a POINTER (%s -> strlen,
 * memcpy, ...), so the faulting instruction is an ordinary byte/word LOAD whose
 * rt != rn.  Those used to be PASSed unconditionally.
 *
 * v2.0 adds a second, evidence-gated path:
 *   (1) the faulting instruction is a LOAD (never repair a store this way --
 *       pointing a store's base at sp would scribble on the stack);
 *   (2) the fault address is a small/untrusted value (< 16 MiB: the family's
 *       q0 spans 0x1c949..0x597004 and its len 1601..72085, all far below);
 *   (3) the faulting process's stack within [sp, sp+16K) contains a 32 B record
 *       whose q0 or low32(q2) equals si_addr (or si_addr +- 8: va_arg may have
 *       advanced).  The record shape is the HARD GATE (w1 == 0 && w3 == 0 &&
 *       length word in band) -- without a record we never repair anything.
 * Repair: point the base register at sp and skip the instruction.  The process
 * survives with a garbage byte instead of dying; because only LOADS are
 * repaired, this cannot turn a bogus pointer into a bogus WRITE.
 */
#define DEREF_SCAN_BYTES (16UL * 1024UL)
#define DEREF_SMALL_MAX  (1UL << 24)
#define NR_LEN_LO 0x400UL
#define NR_LEN_HI 0x20000UL

/* is the faulting instruction a load?  (covers LDR/LDRB/LDRH/LDRSW imm-unsigned
 * and LDUR* unscaled; explicitly excludes the store forms and FP) */
static int is_load_insn(unsigned int insn)
{
    unsigned opc = (insn >> 22) & 3u;

    if ((insn >> 26) & 1u)              /* V=1: FP/SIMD load-store */
        return 0;
    if ((insn & 0x3B000000u) == 0x39000000u)   /* size 111 0 01 opc ... */
        return opc != 0;
    if ((insn & 0x3B200C00u) == 0x38000000u)   /* size 111 0 00 opc imm9 00 */
        return opc != 0;
    return 0;
}

/* coarse class label for the NEAR read-out (never used to decide a repair) */
static const char *classify_insn(unsigned int insn)
{
    unsigned opc = (insn >> 22) & 3u;

    if ((insn >> 26) & 1u) return "fp";
    if ((insn & 0x3B200C00u) == 0x38000000u)
        return opc ? "ldur" : "stur";
    if ((insn & 0x3B000000u) == 0x39000000u) {
        switch ((insn >> 30) & 3u) {
        case 0: return opc ? "ldrb" : "strb";
        case 1: return opc ? "ldrh" : "strh";
        default: return opc ? "ldr" : "str";
        }
    }
    return "other";
}

static int len_band(unsigned long v)
{
    return v >= NR_LEN_LO && v <= NR_LEN_HI;
}

/* search [sp, sp+16K) of the faulting task for a 32 B family record that carries
 * si_addr in q0 or low32(q2).  Page-by-page so an unmapped hole does not abort
 * the whole scan.  Returns 1 and fills the out-params on a hit. */
static int find_record_near_stack(pid_t pid, unsigned long sp, unsigned long addr,
                                  unsigned long *out_va, unsigned long *out_q0,
                                  unsigned long *out_q2, int *out_which)
{
    static unsigned char buf[4096];
    unsigned long base = sp & ~0xFFFUL;
    unsigned long p;
    int pg;

    for (pg = 0; pg < (int)(DEREF_SCAN_BYTES / 4096); pg++) {
        unsigned long va = base + (unsigned long)pg * 4096UL;
        unsigned long off;

        if (read_mem(pid, va, buf, 4096) < 0)
            continue;
        g_deref_scan++;
        /* stride 8.  Measured: the 4 natural-NE records sit at page offsets
         * 0x8ea8/0x8ff0/0xebc8/0x8840/0x9168/0x92b0/0xec70 -- all 8-aligned but
         * NOT all 16-aligned, so a 16 B stride would miss them.  A window that
         * starts inside a record can also match (when the fault address equals
         * the record's length word); that only costs evidence quality, never
         * correctness -- the repair action is identical. */
        for (off = 0; off + 32 <= 4096; off += 8) {
            unsigned long q0, q1, q2, q3, lo0, lo2;

            q0 = *(unsigned long *)(buf + off);
            q1 = *(unsigned long *)(buf + off + 8);
            q2 = *(unsigned long *)(buf + off + 16);
            q3 = *(unsigned long *)(buf + off + 24);
            if (q1 != 0 || q3 != 0)
                continue;
            lo0 = q0 & 0xFFFFFFFFUL;
            lo2 = q2 & 0xFFFFFFFFUL;
            if (lo2 == addr || lo2 == addr + 8 || lo2 == addr - 8) {
                if (!len_band(lo2))
                    continue;
                *out_va = va + off; *out_q0 = q0; *out_q2 = q2; *out_which = 2;
                return 1;
            }
            if (lo0 == addr || lo0 == addr + 8 || lo0 == addr - 8) {
                if (!len_band(lo0))
                    continue;
                *out_va = va + off; *out_q0 = q0; *out_q2 = q2; *out_which = 0;
                return 1;
            }
        }
        p = va;
        (void)p;
    }
    return 0;
}

/* returns 1 if this fault was handled by the dereference-type path */
static int deref_attempt(pid_t pid, struct regs64 *r, unsigned int insn, unsigned long addr)
{
    unsigned long recva = 0, q0 = 0, q2 = 0;
    int which = -1, rn = (int)((insn >> 5) & 0x1F);

    if (!is_load_insn(insn))
        return 0;
    if (addr == 0 || addr >= DEREF_SMALL_MAX)
        return 0;
    if (rn == 31)                       /* base is already sp: nothing to redirect */
        return 0;
    if (!find_record_near_stack(pid, r->sp, addr, &recva, &q0, &q2, &which))
        return 0;
    g_deref_hit++;
    if (g_dry) {
        g_would2++;
        if (rate_ok_prio())
            logev("WOULD_DREPAIR", pid, "pc=%#lx addr=%#lx rn=%d rec=0x%lx which=q%d q2=%#lx",
                  r->pc, addr, rn, recva, which, q2);
        return 0;                       /* dry run: never touch registers */
    }
    {
        int nth = 0;
        if (!breaker_allow(pid, r->pc, &nth)) {
            if (rate_ok()) logev("PASS", pid, "reason=repair-loop pc=%#lx n=%d", r->pc, nth);
            return 0;
        }
    }
    r->regs[rn] = r->sp;
    r->pc += 4;
    {
        struct iovec iov;
        iov.iov_base = r; iov.iov_len = sizeof(*r);
        if (ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, &iov) < 0)
            return 0;
    }
    g_rep2++;
    if (rate_ok_prio())
        logev("DREPAIR", pid, "pc=%#lx addr=%#lx rn=%d rec=0x%lx which=q%d q0=%#lx q2=%#lx",
              r->pc - 4, addr, rn, recva, which, q0, q2);
    return 1;
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
    note_bin(pid);
    if (rate_ok()) logev("SEGV", pid, "pc=%#lx addr=%#lx code=%d x2=%#lx x8=%#lx insn=%#x", r.pc, (unsigned long)si.si_addr, si.si_code, r.regs[2], r.regs[8], insn);
    /* v1.9.2: decode the raw register fields for ANY instruction first, so the
     * NEAR observation below can report rt/rn even when the shape test fails. */
    rt = insn & 0x1F; rn = (insn >> 5) & 0x1F;
    if (!is_ldr_same(insn, &rt, &rn)) {
        g_passed++;
        if (record_probe(pid, &r, (unsigned long)si.si_addr)) {
            g_near_insn++;
            if (rate_ok_prio()) logev("NEAR", pid, "reason=insn shape=%s rt=%d rn=%d insn=%#x addr=%#lx",
                                      classify_insn(insn), rt, rn, insn, (unsigned long)si.si_addr);
        } else if (rate_ok()) {
            logev("PASS", pid, "reason=not-load");
        }
        if (deref_attempt(pid, &r, insn, (unsigned long)si.si_addr)) return 1;
        return 0;
    }
    if (rt != rn) {
        g_passed++;
        if (record_probe(pid, &r, (unsigned long)si.si_addr)) {
            g_near_insn++;
            if (rate_ok_prio()) logev("NEAR", pid, "reason=insn shape=%s rt=%d rn=%d insn=%#x addr=%#lx",
                                      classify_insn(insn), rt, rn, insn, (unsigned long)si.si_addr);
        } else if (rate_ok()) {
            logev("PASS", pid, "reason=rt-ne-rn rt=%d rn=%d", rt, rn);
        }
        if (deref_attempt(pid, &r, insn, (unsigned long)si.si_addr)) return 1;
        return 0;
    }
    if ((unsigned long)si.si_addr != r.regs[rt]) {
        g_passed++;
        if (record_probe(pid, &r, (unsigned long)si.si_addr)) {
            g_near_insn++;
            if (rate_ok_prio()) logev("NEAR", pid, "reason=insn shape=%s rt=%d rn=%d insn=%#x addr=%#lx",
                                      classify_insn(insn), rt, rn, insn, (unsigned long)si.si_addr);
        } else if (rate_ok()) {
            logev("PASS", pid, "reason=addr-ne-xt");
        }
        if (deref_attempt(pid, &r, insn, (unsigned long)si.si_addr)) return 1;
        return 0;
    }
    if (read_mem(pid, r.regs[2], w, 32) < 0) {
        g_passed++;
        if (rate_ok()) logev("PASS", pid, "reason=x2-unreadable");
        if (deref_attempt(pid, &r, insn, (unsigned long)si.si_addr)) return 1;
        return 0;
    }
    if (!shape_ok(w, (unsigned long)si.si_addr)) {
        unsigned long fa = (unsigned long)si.si_addr;
        g_passed++;
        /* v1.9 NEAR: w1==0 and w0 matches the fault address, yet a hardening clause
         * (w3 != 0, or the length band) rejected it.  A non-zero NEAR count in a
         * dry-run window means the v1.8 tightening may be excluding real family
         * members and must be reviewed BEFORE arming -- this is the read-out that
         * makes the strictness safe to deploy. */
        if (w[1] == 0 && (w[0] == fa || w[0] == fa + 8)) {
            g_near++;
            if (rate_ok_prio())
                logev("NEAR", pid, "pc=%#lx fault=%#lx code=%d w=%#lx,%#lx,%#lx,%#lx",
                      r.pc, fa, si.si_code, w[0], w[1], w[2], w[3]);
        } else if (rate_ok()) {
            logev("PASS", pid, "reason=shape-fail w=%#lx,%#lx,%#lx,%#lx", w[0], w[1], w[2], w[3]);
        }
        if (deref_attempt(pid, &r, insn, (unsigned long)si.si_addr)) return 1;
        return 0;
    }
    {   /* v1.9: (pid, faulting-site) consecutive breaker -- see breaker_allow(). */
        int nth = 0;
        if (!breaker_allow(pid, r.pc, &nth)) {
            g_passed++; g_loop++;
            if (rate_ok()) logev("PASS", pid, "reason=repair-loop pc=%#lx n=%d", r.pc, nth);
            return 0;
        }
    }
    if (g_dry) {
        /* Dry run: record what WOULD have been repaired and hand the signal back to
         * the tracee (the caller PTRACE_CONTs with the signal).  Registers are NOT
         * touched and no signal is swallowed -- the process dies exactly as it would
         * with nerepair absent, so the natural NE census stays valid. */
        g_would++;
        if (rate_ok_prio())
            logev("WOULD_REPAIR", pid, "pc=%#lx fault=%#lx rt=%d code=%d",
                  r.pc, (unsigned long)si.si_addr, rt, si.si_code);
        return 0;
    }
    r.regs[rt] = r.sp;
    r.pc += 4;
    iov.iov_base = &r; iov.iov_len = sizeof r;
    if (ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, &iov) < 0) { g_passed++; if (rate_ok()) logev("PASS", pid, "reason=setregs"); return 0; }
    g_repaired++;
    if (rate_ok_prio()) logev("REPAIR", pid, "pc=%#lx fault=%#lx rt=%d code=%d", r.pc - 4, (unsigned long)si.si_addr, rt, si.si_code);
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
    int st; pid_t w; time_t deadline;
    if (pid == self_pid || pid <= 0) return;
    if (ptrace(PTRACE_ATTACH, pid, 0, 0) < 0) return;
    /* v1.4: EINTR-retry (SIGALRM has no SA_RESTART since v1.3) and detach on
     * any other wait failure -- a tracee abandoned in group-stop is frozen
     * for good (PTRACE_DETACH on a dead/non-stopped pid just fails softly).
     * v1.5: bounded wait -- a D-state/unstoppable tracee may never report the
     * attach stop, and an unbounded (even EINTR-correct) wait freezes the
     * supervisor itself: field 2026-10-31 07:05-07:08, heartbeat silent for
     * 234s and the watchdog killed us.  WNOHANG polling with a 3s deadline;
     * on timeout PTRACE_DETACH and give up on this pid (better a missing
     * tracee than a frozen supervisor). */
    deadline = time(NULL) + 3;
    for (;;) {
        w = waitpid(pid, &st, __WALL | WNOHANG);
        if (w == pid) break;
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 || time(NULL) > deadline) {
            ptrace(PTRACE_DETACH, pid, 0, 0);
            return;
        }
        usleep(20000);
    }
    if (!WIFSTOPPED(st)) { ptrace(PTRACE_DETACH, pid, 0, 0); return; }
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
        /* v1.8: was "p > 1", so a failed first attach to PID 1 was never retried
         * (attach_pid has a 3s deadline and can give up).  traced() still gates it. */
        if (p != self_pid && !traced(p)) attach_pid(p);
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
static unsigned g_ticks;
static void on_alarm(int s) { (void)s; g_alarm = 1; }
static void on_term(int s) { (void)s; g_term = 1; }
static void on_usr1(int s) { (void)s; g_usr1 = 1; }
int main(void)
{
    int st; pid_t pid;
    struct stat statb;
    self_pid = getpid();
    /* v1.9 dry-run selection order: env NEREPAIR_DRY=1 > marker file. */
    if (getenv("NEREPAIR_DRY") && *getenv("NEREPAIR_DRY") && strcmp(getenv("NEREPAIR_DRY"), "0"))
        g_dry = 1;
    else if (stat("/data/gw/nerepair.dry", &statb) == 0)
        g_dry = 1;
    canary_init();
    logfd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    logev("START", 0, "pid=%d ver=%s dry=%d canary=%s resolved=%d",
          self_pid, NEREPAIR_VER, (int)g_dry, g_can_ok ? g_can_path : "-", g_can_ok);
    if (g_dry)
        logev("MODE", 0, "dry=1 source=%s", getenv("NEREPAIR_DRY") ? "env" : "marker");
    write_hb();
    { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_alarm; sa.sa_flags = 0; sigaction(SIGALRM, &sa, NULL); }
    { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_term; sa.sa_flags = 0; sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); }
    { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_usr1; sa.sa_flags = 0; sigaction(SIGUSR1, &sa, NULL); }
    alarm(60);
    if (!traced(1)) attach_pid(1);
    scan_proc();
    logev("SCAN", 0, "attached_total=%lu", g_attached);
    for (;;) {
        /* v1.7: 心跳改在循环顶消费 g_alarm —— 原实现只在 waitpid 返回 EINTR
         * 的分支里检查该标志; tracee 事件风暴(fork/exec/信号停止连发)期间
         * waitpid 永远有排队停止可返、不阻塞也就不 EINTR, 标志被置却无人
         * 消费, 心跳被无限饿死(实弹 2026-10-31 18:00 巡检: 5 次 284-651s
         * 断流, 两次 230/242s 触发看门狗重启)。循环顶检查使心跳节奏与事件
         * 风暴解耦; EINTR 分支保留原逻辑作兜底。 */
        if (g_alarm) {
            g_alarm = 0; alarm(60); write_hb();
            logev("STAT", 0, "mode=%s attached=%lu segv=%lu repaired=%lu passed=%lu suppressed=%lu abuse=%lu loop=%lu would=%lu near=%lu nearinsn=%lu rep2=%lu would2=%lu dfhit=%lu",
                  g_dry ? "dry" : "armed", g_attached, g_segv, g_repaired, g_passed,
                  g_suppressed, g_abuse, g_loop, g_would, g_near, g_near_insn,
                  g_rep2, g_would2, g_deref_hit);
            /* v1.9: PID 1 coverage must not depend on the first attach winning --
             * attach_pid gives up after 3s on a busy boot.  Retry every 60s. */
            if (!traced(1)) { attach_pid(1); logev("PID1RETRY", 1, "attached=%lu", g_attached); }
            /* v1.9: full /proc rescan every 10 minutes (traced() gates the cost). */
            if (++g_ticks % 10 == 0) scan_proc();
        }
        if (g_usr1) {
            g_usr1 = 0;
            g_dry = g_dry ? 0 : 1;
            logev("MODE", 0, "dry=%d by=SIGUSR1", (int)g_dry);
        }
        if (g_term) {
            logev("EXIT", 0, "signal attached=%lu segv=%lu repaired=%lu passed=%lu suppressed=%lu",
                  g_attached, g_segv, g_repaired, g_passed, g_suppressed);
            return 0;
        }
        pid = waitpid(-1, &st, __WALL);
        if (pid < 0) {
            if (errno == EINTR) {
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
