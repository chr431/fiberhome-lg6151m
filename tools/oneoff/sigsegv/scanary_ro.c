/* scanary.c -- self-scanning canary for the 32B-record SIGSEGV family.
 *
 * kdev / task-1 (+ Lead's DEPTH ARM, 2026-11-01).  Host: tmpfiles/repro/scanary/.
 * Device: /data/repro/scanary.
 *
 * ============================ WHAT IT IS ============================
 * The old canary (vsurv4) only yields data WHEN the record lands on the live
 * va_list and the process dies  => hard selection effect.  scanary removes it:
 * a helper thread re-reads the victim's stack mapping and a never-touched decoy
 * mapping every few ms and logs EVERY 32-byte window matching the historical
 * record shape, crash or no crash.
 *
 * ============================ THE DEPTH ARM ============================
 * Two models both explain "top-x2 == 0x390 in 2552/2552 dumps":
 *   H1  the writer targets the LIVE va_list address  -> address tracks depth
 *   H2  the writer targets a FIXED stack-top-relative offset (top-0x390)
 *       and vsurv4 simply always keeps its va_list there
 * Discriminator: change the call depth.  The victim pads its frame by D bytes
 * before the variadic call, D in {0,0x100,0x400,0x900,0x1000}, one epoch each.
 *   record (top-VA)    follows D          => H1
 *   record (top-VA)    fixed at 0x390     => H2
 *   record (sp_call-VA) fixed             => H1 (stronger form)
 *   neither                               => new model, report immediately
 * Every hit line carries ep=<epoch> D=<pad> so the analysis needs no guessing.
 *
 * ============================ SHAPE ============================
 * rule version R1 (historical 150-sample layout, 09_CONDITIONAL.md):
 *   +0x00 u64 w0 : arbitrary            (0..597004 observed)
 *   +0x08 u64 w1 : == 0                 (150/150)
 *   +0x10 u32 len: 0x40..0x20000        (1601/1664 typical)
 *   +0x14 be32 ip: unicast IPv4         (192.168.9.1 / 110.65.x.x typical)
 *   +0x18 u64 w3 : == 0                 (150/150)
 * rule bits  R2 loose(w1==0&&w3==0&&w2!=0) | R1 strict | R1L strict+private-ip
 *            R3 exact w2==0x0109a8c000000641
 *
 * ============================ SAFETY / SELF-CHECK ============================
 *  - victim runs either on a PRIVATE mmap'd stack (default; controlled geometry)
 *    or on the main thread's initial stack (--victim=main; top == start_stack,
 *    directly comparable with the 2552 historical dumps)
 *  - the private stack is pre-poisoned 0x5a so untouched bytes cannot fake a hit
 *  - the decoy (8 MB, pre-poisoned, never a stack) is the clean null: a match
 *    there is an external write, full stop
 *  - on a hit the 32B is overwritten with a SENTINEL (decoy always; private
 *    stack only below the deepest observed sp; live frames only with
 *    --writeback=all).  If a record reappears at the same VA after the sentinel
 *    that is an external re-write -> strongest evidence obtainable without a
 *    kernel module.
 *
 *  SELF-CHECK (mandatory, fail-closed):
 *   T1 positive : synthetic record in the decoy            -> must be found
 *   T2 positive : synthetic record in the stack safe zone  -> must be found
 *   T3 negative : 32B window with w1!=0 (near miss)        -> must NOT be found
 *   T4 hot-slot : synthetic record at top-0x390 (the historical landing zone,
 *                 inside the live frame area)               -> must be found;
 *                 it may also crash the victim, which then appears as
 *                 SELFCRASH and is a bonus end-to-end positive control
 *   Continuous  : every --probe-sec a rotating decoy slot gets a synthetic
 *                 record and must be found within 2 passes (scanner liveness)
 *   Any T1..T4 failure => SELFTEST_FAIL, exit(2).  Probe misses are counted and
 *   reported; they never silently degrade a "0 hits" into a clean zero.
 *
 * ============================ BUILD ============================
 *   host   : gcc -O2 -pthread -o scanary_host scanary.c
 *   device : zig cc -target aarch64-linux-musl -O2 -static -pthread -o scanary scanary.c
 */
#define _GNU_SOURCE
#include <dirent.h>      /* F2 instance census */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sched.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

#define VERSION    "scanary-ro-1.25"
#define PAGE       4096UL
#define REC_BYTES  32
#define MAXSLOT    1024
#define MAXDEPTH   8
#define SENT_W0    0x5ca95ca95ca95ca9ULL
#define POISON     0x5a5a5a5a5a5a5a5aULL
#define INJ_W0     0x5ca9a41e5ca9a41eULL

/* ------------------------------------------------------------------ config */
static size_t cfg_stack  = 2UL << 20;   /* private stack size / main-stack window */
static size_t cfg_decoy  = 8UL << 20;
static long   cfg_period = 5000;        /* us; spec says <= 10000 */
static long   cfg_hold   = 10000;       /* us spent inside the deep frame; 0 = full speed */
static int    cfg_hmode  = 0;           /* 0 = nanosleep hold (syscall), 1 = pure user-mode busy hold (D14/H6) */
static int    cfg_wb     = 1;           /* 0 none | 1 safe | 2 all            */
static int    cfg_dur    = 0;
static int    cfg_selft  = 1;
static int    cfg_probe  = 120;
static int    cfg_churn  = 0;
static int    cfg_logrule= 1;           /* 0 R2 | 1 R1 | 2 R3 | 3 all         */
static long   cfg_ctxmax = 200;         /* full 32B+/-256B context dumps, 0=off */
static long   cfg_ctxbytes = 256;       /* U-D1/E2: half-window for context dumps */
static int    cfg_spin   = 0;           /* U-D1/E3: victim spins with zero syscalls */
static int    cfg_cpu    = -1;          /* U-D1/E4: pin victim thread to this CPU */
static int    cfg_stride = 16;
static int    cfg_main   = 0;           /* 1 = victim on the main thread stack */
static int    cfg_epoch  = 60;          /* seconds per depth epoch, 0 = single */
static int    cfg_cycle  = 0;           /* 1 = wrap the depth list until --duration */
static unsigned long cfg_depths[MAXDEPTH] = {0, 0x100, 0x400, 0x900, 0x1000};
static int    cfg_ndepth = 5;
static const char *cfg_log    = "/data/repro/scanary.log";
static const char *cfg_patrace= 0;

#define RB_R2   1u
#define RB_R1   2u
#define RB_R1L  4u
#define RB_R3   8u

static int          g_pid;
static int          g_logfd = -1;
static volatile sig_atomic_t g_stop;
static unsigned long g_t0_us;

/* ------------------------------------------------------------------ region */
struct region { const char *name; unsigned char *base; size_t size; };
static struct region g_rs;          /* victim stack (mmap or [start_stack-N,start_stack]) */
static struct region g_rd;          /* decoy                                            */
static unsigned char *g_rs_top;     /* the "top" every offset is reported against       */
static int            g_rs_heap;    /* 1 = we own the mapping (poisoned), 0 = main stack*/

/* ------------------------------------------------------------------ victim */
static pthread_t            g_victim;
static volatile int         g_victim_up;
static volatile unsigned long g_sp_low;
static volatile unsigned long g_sp_call;    /* sp seen at the variadic call site */
static volatile unsigned long g_last_ap;    /* U-D1: &ap inside vcall (frame probe) */
static volatile unsigned long g_last_ts;    /* U-D1: &timespec inside hold_sleep */
static int g_frame_logged;
static volatile unsigned long g_iters;
static volatile unsigned long g_depth;      /* current frame pad (bytes)         */
static volatile int          g_epoch;
static volatile unsigned int g_selfcrash;
static sigjmp_buf           g_jb;
static volatile sig_atomic_t g_ready;
static volatile sig_atomic_t g_in_handler;
static unsigned char        g_altstack[64 * 1024] __attribute__((aligned(16)));

/* ------------------------------------------------------------------ stats  */
static unsigned long st_pass, st_bytes, st_cand, st_r2only;
static unsigned long st_appear, st_rewrite, st_rewrite_none;
static unsigned long st_probe_ok, st_probe_bad, st_overflow;
static unsigned long st_selft_ok, st_selft_bad;
static unsigned long st_scan_us_sum, st_scan_us_max;
static unsigned long st_ctx_emitted, st_ctx_skipped;
static int           g_epoch_idx;

/* ------------------------------------------------------------------ slots  */
struct slot {
    unsigned long va;
    uint64_t      w[4];
    unsigned long t0, tlast;
    int           region;
    unsigned      rule;
    int           injected, sentineled;
    unsigned long sent_at;
};
static struct slot g_slot[MAXSLOT];

/* --------------------------------------------------------------- utilities */
static unsigned long now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long)(ts.tv_sec * 1000000UL + ts.tv_nsec / 1000UL) - g_t0_us;
}

static int f_dec(char *p, unsigned long v)
{
    char t[24]; int n = 0, i;
    if (!v) { p[0] = '0'; return 1; }
    while (v && n < (int)sizeof(t)) { t[n++] = (char)('0' + (v % 10)); v /= 10; }
    for (i = 0; i < n; i++) p[i] = t[n - 1 - i];
    return n;
}
static int f_hex(char *p, unsigned long v)
{
    static const char h[] = "0123456789abcdef";
    char t[24]; int n = 0, i;
    if (!v) { p[0] = '0'; return 1; }
    while (v && n < (int)sizeof(t)) { t[n++] = h[v & 0xf]; v >>= 4; }
    for (i = 0; i < n; i++) p[i] = t[n - 1 - i];
    return n;
}
static int s_cat(char *p, int n, int cap, const char *s)
{
    while (*s && n < cap - 1) p[n++] = *s++;
    p[n] = 0;
    return n;
}
static int f_cat_hex(char *p, int n, int cap, const char *pre, unsigned long v)
{
    n = s_cat(p, n, cap, pre);
    n = s_cat(p, n, cap, "0x");
    n += f_hex(p + n, v); p[n] = 0;
    return n;
}
static int f_cat_dec(char *p, int n, int cap, const char *pre, unsigned long v)
{
    n = s_cat(p, n, cap, pre);
    n += f_dec(p + n, v); p[n] = 0;
    return n;
}
static void emit(const char *line, int len)
{
    if (g_logfd >= 0 && len > 0)
        if (write(g_logfd, line, (size_t)len) < 0) { /* keep going */ }
}
static void logline(const char *fmt, ...)
{
    char b[640];
    va_list ap;
    int n;
    n = s_cat(b, 0, (int)sizeof(b), "EV ");
    n += f_dec(b + n, now_us()); b[n] = 0;
    b[n++] = ' ';
    va_start(ap, fmt);
    n += vsnprintf(b + n, sizeof(b) - (size_t)n - 2, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof(b) - 2) n = (int)sizeof(b) - 2;
    b[n++] = '\n';
    emit(b, n);
}

/* ------------------------------------------------------------ RO arm (v1.7) ----
 * TARGET: the page holding the victim's LIVE va_list -- the address of "ap" inside
 * the variadic wrapper below -- NOT start_stack-0x390 (C-171: the landing point
 * follows the live frame, residual 0).  Field data 2026-11-03 (RW arm, --depth-list 0,
 * 600 s): 15 inj=0 hits, all on page 0x7fe1650000, poff 0xdb0/topva 0x350 and
 * poff 0xb10/topva 0x5f0, len 1583-1635 with a real public payload.
 *
 * ARCHITECTURE (three stacks, no frame of the window runs on the guarded page)
 *   victim  : publishes {vap,sec,arm} in GLOBALS, then swapcontext()s onto a private
 *             park stack (PARK, 64 KiB mmap) where it loops in nanosleep/futex with
 *             an explicit PARKED state + sp print.  It never returns to its own frame
 *             while the page is RO -- that was the v1.6 defect (the window used to run
 *             in the victim's frame, which IS on the guarded page).
 *   helper  : a thread created at startup on a dedicated 256 KiB mmap'd stack (RO).
 *             It waits for PARKED, snapshots the page, mprotect(PROT_READ), sleeps S,
 *             restores RW *before* any dump, snapshots the page again, diffs it, then
 *             publishes the result and wakes the park loop.
 *   guards  : (a) probe guard [&probe-256, &probe+256) vs the page -- keeps the field
 *             diagnostic RO_INVALID reason=helper_same_page (instrument self-protection,
 *             observed on device 2026-11-03, must stay);
 *             (b) LIVE-RANGE guard [sp, sp+RO_FRAME_EXTENT) vs the page for BOTH the
 *             helper's own sp and the parked victim's sp, checked before the mprotect
 *             and again after the restore.  Stacks grow down, so the live frame is
 *             [sp, sp+extent), not a single point.
 *   sigaltstack is PER THREAD: the victim thread and the helper thread each install
 *   their own, otherwise SA_ONSTACK falls back to the current (possibly RO) stack.
 *
 * OUTPUT (per window): VAP / PARKED / RO_BEFORE(32 B @&ap) / PAGEMAP(page-level
 * changed-byte runs) / SHAPE(family-shape filter over the page) / APWIN(&ap +-64 B
 * auxiliary only) / RO_END(result=CHANGED|UNCHANGED).  The preregistered "diff within
 * &ap+-64 B" is an AUXILIARY signal only: the field saw two distinct poff values
 * (0xdb0, 0xb10, delta 0x2a0), so the page-level map is the primary判据.
 *
 * HARD PRECONDITION: --depth-list 0 (single, zero pad) and --cycle 0; anything else
 * prints RO_INVALID reason=depth_list_not_zero and refuses to arm (fail-closed).
 * --ro=1 RO arm / --ro=0 RW control arm (same cadence, no mprotect; CTRL_INVALID
 * reason=no_change if it never observes a write).
 */
static unsigned long read_sp(void);        /* defined further below (aarch64/x86 asm) */
static void ro_victim_window(va_list *app);

/* ------------------------------------------------------------ RO arm (v1.11) ---
 * TARGET: the page holding the victim's LIVE va_list (&ap in the variadic wrapper),
 * not start_stack-0x390 (C-171).  Field: 15 inj=0 hits / 600 s on one page (RW arm),
 * and window experiments showed that page changing inside a 1 s window.
 *
 * PROTOCOL (value-semantic futex, NO signals, NO stale wake-ups):
 *   victim : writes {vap,sec,arm}+seq in GLOBALS, futex-wakes the helper, publishes
 *            g_vic_waiting=seq, then blocks in a raw FUTEX_WAIT loop that touches only
 *            globals (no stack writes).  It resumes only after the helper has already
 *            restored the page to RW.
 *   helper : own 256 KiB mmap'd stack (pthread_attr_setstack).  Waits for the request,
 *            confirms g_vic_waiting==seq AND /proc/self/task/<tid>/stat state S/D
 *            (positive proof the victim is blocked, not running), then:
 *            snapshot page -> mprotect(RO) -> nanosleep(S) -> mprotect(RW) -> snapshot
 *            -> diff -> log, then publishes g_ro_done=seq and futex-wakes the victim.
 *   Why not one thread + svc: field 2026-11-04 -- a signal arriving inside the svc-only
 *            window longjmp'ed the victim back onto the still-read-only page and produced
 *            a 23k-crash self-harm storm.  With the helper, the window code never runs on
 *            the guarded page and the victim cannot resume early.
 * Guards: live-range [sp, sp+16 KiB) vs page, checked for the HELPER only (the parked
 *   victim is proven blocked by the state check; its sp is inside the guarded page by
 *   construction, so guarding it would always trip).
 * --ro=1 RO arm / --ro=0 RW control arm (same cadence, no mprotect; CTRL_INVALID if the
 *   RW arm never sees a change).  Per window: VAP / PARKED_CONFIRMED / RO_BEFORE /
 *   PAGEMAP(runs) / SHAPE(family filter) / APWIN(&ap+-64B auxiliary) / RO_END.
 */
#ifndef FUTEX_WAIT
#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#endif
#define RO_STACK_BYTES  (256UL << 10)
#define RO_STACK_GAP    (64UL << 10)   /* unused mapping below the helper stack: an
                                        * accidental underflow must NOT reach the guarded page */
#define RO_GUARD_PAD    256UL
#define RO_FRAME_EXTENT (16UL << 10)

static int  cfg_ro = -1, cfg_ro_sec = 1, cfg_ro_loops = 1;
/* v1.21 pulse arm (Phase-2a, HANDOFF 2026-11-04): short RO pulses while the victim
 * KEEPS RUNNING and consuming its va_list.  Constraint 1 (writer only writes a
 * running victim) made "park + long RO" worthless; constraint "victim must consume
 * va_list" made "running + long RO" impossible.  The pulse is the only shape that
 * satisfies both.  --pulse ON_MS OFF_MS (1 1 = 1 ms RO / 1 ms RW, 50% duty). */
static unsigned long cfg_pulse_on, cfg_pulse_off;   /* microseconds, 0 = off */
static unsigned long cfg_pulse_loops;               /* 0 = until --duration */
/* v1.20 time-correlation arm: --idle-us N (sleep between calls, OUTSIDE the frame),
 * --calltrace 1 (log CALL_BEGIN/CALL_END around every hot_call iteration). */
static unsigned long cfg_idle;      /* microseconds of idle between calls (0 = off) */
static int           cfg_calltrace; /* log per-iteration call windows            */
static unsigned char *g_vbuf, *g_ro_stack;
static unsigned long g_ro_page, g_ro_vap_first, g_ro_vc0;
static int g_ro_inst = -1;      /* F2: instances of this exact comm (self excluded) */
static unsigned long st_ro_win, st_ro_changed, st_ro_unchanged, st_ro_fault, st_ro_invalid;
static unsigned long st_ro_wb_skipped;   /* sentinel writes refused because a page was RO */
static int           g_ro_stop, g_ro_drift, g_ro_helper_up, g_ro_woke, g_ro_woke_flag;
static volatile sig_atomic_t g_ro_abort;
/* v1.21 pulse state: PULSE_ON/PULSE_OFF transition log lines + counters.  The
 * victim's own va_list stores fault during PULSE_ON and are longjmp-recovered by
 * the existing segv() handler (SA_ONSTACK, per-thread altstack, victim-only
 * siglongjmp -- all the v1.6/v1.14/v1.15 lessons already baked in). */
static volatile unsigned long g_pulse_state;   /* 0 = RW, 1 = RO (visible to segv) */
static unsigned long st_pulse_on, st_pulse_off, st_pulse_vfault, st_pulse_early;

static volatile int  g_ro_req, g_ro_done, g_ro_arm, g_ro_req_sec, g_vic_waiting, g_ro_helper_end;
static volatile unsigned long g_ro_req_vap, g_vic_seq;
static volatile int  g_vic_tid;
static volatile unsigned long g_vic_tls_page;   /* v1.19 PAGE_IS_TLS guard */
static pthread_t     g_ro_thread;

/* forward: the pulse window + duty helper (v1.21) */
static void ro_pulse_window(int seq);
static unsigned long duty_x10(unsigned long on_us_total, unsigned long cycles);

/* v1.12 safety (Lead 2026-11-04): a window must never be able to hold the page
 * read-only past its own deadline, and SIGTERM/SIGINT must work DURING a window.
 * Both restore RW first, then exit with a distinct code. */
static void on_term_win(int sig)
{
    (void)sig;
    if (g_ro_page) (void)mprotect((void *)g_ro_page, PAGE, PROT_READ | PROT_WRITE);
    _exit(3);
}
static void ro_emergency_restore(const char *why)
{
    unsigned long p = g_ro_page;
    g_ro_page = 0;
    logline("RO_ERR stage=%s page=0x%lx restoring=1 exiting=3", why, p);
    if (p) (void)mprotect((void *)p, PAGE, PROT_READ | PROT_WRITE);
    if (g_logfd >= 0) { close(g_logfd); }
    _exit(3);
}

/* v1.19: the thread's TCB/TLS base (aarch64 tpidr_el0).  musl keeps the TCB in the
 * TOP page of the thread stack, so if the va_list page ever equals the TLS page an RO
 * window is impossible by construction (any errno/TLS access would fault). */
static inline unsigned long ro_tls_base(void)
{
#if defined(__aarch64__)
    unsigned long v;
    __asm__ __volatile__("mrs %0, tpidr_el0" : "=r"(v));
    return v;
#else
    return 0;
#endif
}

static inline __attribute__((always_inline)) long ro_futex(int op, volatile int *addr, int val)
{
    register long x0 asm("x0") = (long)(uintptr_t)addr;
    register long x1 asm("x1") = (long)op;
    register long x2 asm("x2") = (long)val;
    register long x3 asm("x3") = 0L;
    register long x8 asm("x8") = 98;                  /* __NR_futex */
    asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x8));
    return x0;
}

static void ro_hex(const char *tag, unsigned long va, const unsigned char *p)
{
    char b[256]; int n = 0, i;
    n = s_cat(b, 0, (int)sizeof(b), tag);
    n = f_cat_hex(b, n, (int)sizeof(b), " va=", va);
    n = s_cat(b, n, (int)sizeof(b), " hex=");
    for (i = 0; i < REC_BYTES && n < (int)sizeof(b) - 3; i++) {
        b[n++] = "0123456789abcdef"[p[i] >> 4];
        b[n++] = "0123456789abcdef"[p[i] & 0xf];
    }
    b[n] = 0;
    logline("%s", b);
}

static int ro_live_guard(unsigned long page, const char *who, unsigned long sp)
{
    unsigned long lo = sp, hi = sp + RO_FRAME_EXTENT;
    if (!sp) return 0;
    if (hi >= page && lo < page + PAGE) {
        st_ro_invalid++;
        logline("GUARD who=%s sp_range=[0x%lx,0x%lx) page=0x%lx overlap=1", who, lo, hi, page);
        logline("RO_INVALID reason=live_stack_overlap who=%s sp=0x%lx range=[0x%lx,0x%lx) page=0x%lx",
                who, sp, lo, hi, page);
        g_ro_stop = 1; return -1;
    }
    logline("GUARD who=%s sp_range=[0x%lx,0x%lx) page=0x%lx overlap=0", who, lo, hi, page);
    return 0;
}

/* confirm the victim thread is not running (state S/D) */
static int ro_victim_blocked(int seq)
{
    struct timespec t = {0, 1000000L};
    int i;
    for (i = 0; i < 2000 && g_vic_waiting != seq; i++) nanosleep(&t, 0);
    if (g_vic_waiting != seq) return -1;
    for (i = 0; i < 50; i++) {
        char p[64], b[256]; int fd, n; char *q;
        struct timespec t2 = {0, 500000L};
        snprintf(p, sizeof p, "/proc/self/task/%d/stat", g_vic_tid);
        fd = open(p, O_RDONLY);
        if (fd >= 0) {
            n = (int)read(fd, b, sizeof b - 1); close(fd);
            if (n > 0) {
                b[n] = 0; q = strrchr(b, ')');
                if (q && q[1] == ' ' && (q[2] == 'S' || q[2] == 'D')) {
                    logline("PARKED_CONFIRMED tid=%d state=%c seq=%d", g_vic_tid, q[2], seq);
                    return 0;
                }
            }
        }
        nanosleep(&t2, 0);
    }
    return -2;
}

/* ---- helper side: the whole window runs here, never on the guarded page ---- */
/* F2: single-victim assertion -- exact comm match (no pgrep substring), self excluded */
static int ro_count_instances(char *comm_out, size_t cn)
{
    DIR *d = opendir("/proc");
    struct dirent *de;
    int self = (int)getpid(), n = 0;
    char own[64] = "?";
    {
        int fd = open("/proc/self/comm", O_RDONLY);
        if (fd >= 0) {
            int r = (int)read(fd, own, sizeof own - 1);
            close(fd);
            if (r > 0) { own[r] = 0; char *p = strchr(own, '\n'); if (p) *p = 0; }
        }
    }
    if (comm_out) { snprintf(comm_out, cn, "%s", own); }
    if (!d) return 1;
    while ((de = readdir(d))) {
        char p[64], b[64]; int fd, r, pid;
        if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
        pid = atoi(de->d_name);
        if (pid == self) continue;
        snprintf(p, sizeof p, "/proc/%s/comm", de->d_name);
        fd = open(p, O_RDONLY);
        if (fd < 0) continue;
        r = (int)read(fd, b, sizeof b - 1);
        close(fd);
        if (r <= 0) continue;
        b[r] = 0;
        { char *q = strchr(b, '\n'); if (q) *q = 0; }
        if (!strcmp(b, own)) n++;          /* exact comm, not substring */
    }
    closedir(d);
    return n;
}

/* F3: positive control -- the victim must not have been scheduled inside the window */
static unsigned long ro_ctxt_switches(int tid)
{
    char p[64], b[512]; int fd, n; char *q;
    snprintf(p, sizeof p, "/proc/self/task/%d/status", tid);
    fd = open(p, O_RDONLY);
    if (fd < 0) return 0;
    n = (int)read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return 0;
    b[n] = 0;
    q = strstr(b, "voluntary_ctxt_switches:");
    if (!q) return 0;
    return strtoul(q + 25, 0, 10);
}

static void ro_do_window(int seq)
{
    static unsigned char before[REC_BYTES], after[REC_BYTES];
    static unsigned char pg_before[PAGE], pg_after[PAGE];
    static struct timespec ts;
    unsigned long va = g_ro_req_vap;
    unsigned long page = va & ~(PAGE - 1);
    unsigned long apoff = va & (PAGE - 1);
    int sec = g_ro_req_sec, i, diff = 0, runs = 0, changed = 0, shapes = 0, rc;

    if (st_ro_win >= (unsigned long)cfg_ro_loops) return;
    if (g_ro_vap_first && va != g_ro_vap_first) {
        st_ro_invalid++; g_ro_drift = 1;
        logline("RO_INVALID reason=vap_drift first=0x%lx now=0x%lx D=0x%lx", g_ro_vap_first, va, g_depth);
        g_ro_stop = 1; return;
    }
    if (!g_ro_vap_first) g_ro_vap_first = va;
    if (ro_victim_blocked(seq) != 0) {
        st_ro_invalid++;
        logline("RO_INVALID reason=victim_not_parked vap=0x%lx tid=%d waiting=%d seq=%d",
                va, g_vic_tid, (int)g_vic_waiting, seq);
        g_ro_stop = 1; return;
    }
    if (g_vic_tls_page && page == g_vic_tls_page) {     /* v1.19 PAGE_IS_TLS */
        st_ro_invalid++;
        logline("RO_INVALID reason=ap_on_tls_page page=0x%lx tls_page=0x%lx "
                "note=va_list page IS the thread TCB page => RO impossible", page, g_vic_tls_page);
        g_ro_stop = 1; return;
    }
    if (g_vic_tls_page)
        logline("GUARD_TLS page=0x%lx tls_page=0x%lx same_page=0", page, g_vic_tls_page);
    if (ro_live_guard(page, "helper", read_sp()) != 0) return;
    {   unsigned long vc0 = ro_ctxt_switches(g_vic_tid);
        /* ... window runs below ... */
        g_ro_vc0 = vc0;
    }

    memcpy(before, (const void *)va, REC_BYTES);
    memcpy(pg_before, (const void *)page, PAGE);
    st_ro_win++;
    logline("VAP idx=%lu vap=0x%lx page=0x%lx poff=0x%lx D=0x%lx topminusap=0x%lx mode=%s sec=%d "
            "helper_sp=0x%lx", st_ro_win, va, page, apoff, g_depth,
            (unsigned long)g_rs_top - va, g_ro_arm ? "ro" : "rw", sec, read_sp());
    ro_hex("RO_BEFORE", va, before);

    if (g_ro_arm) {
        g_ro_page = page;
        rc = mprotect((void *)page, PAGE, PROT_READ);
        if (rc != 0) {
            st_ro_invalid++;
            logline("RO_ERR stage=mprotect_ro page=0x%lx errno=%d", page, errno);
            g_ro_page = 0; g_ro_stop = 1; return;
        }
        logline("RO_ON page=0x%lx prot=PROT_READ", page);
    }
    {   unsigned long t0 = now_us(), last_chk = t0;
        unsigned long lim = (unsigned long)(sec + 60) * 1000000UL;    /* hard cap */
        while (now_us() - t0 < (unsigned long)sec * 1000000UL) {
            if (g_ro_abort) { ro_emergency_restore("helper_abort"); }
            if (now_us() - t0 > lim) { ro_emergency_restore("helper_timeout"); }
            if (now_us() - last_chk >= 60000000UL) {                  /* v1.19: re-census every 60 s */
                int n;
                last_chk = now_us();
                n = ro_count_instances(0, 0);
                if (n > 0) {
                    logline("RO_INVALID reason=multi_instance_late count=%d arm=void", n);
                    if (g_ro_page) (void)mprotect((void *)g_ro_page, PAGE, PROT_READ | PROT_WRITE);
                    g_ro_page = 0;
                    _exit(4);
                }
            }
            ts.tv_sec = 0; ts.tv_nsec = 50000000L;                    /* 50 ms slices */
            nanosleep(&ts, 0);
        }
    }
    if (g_ro_arm) {
        rc = mprotect((void *)page, PAGE, PROT_READ | PROT_WRITE);   /* restore BEFORE any dump */
        g_ro_page = 0;
        if (rc != 0) {
            st_ro_invalid++;
            logline("RO_ERR stage=mprotect_rw page=0x%lx errno=%d", page, errno);
            g_ro_stop = 1; return;
        }
        logline("RO_OFF page=0x%lx prot=PROT_READ|PROT_WRITE", page);
        {   unsigned long vc1 = ro_ctxt_switches(g_vic_tid);
            if (vc1 != g_ro_vc0) {
                g_ro_woke = 1;
                st_ro_invalid++;
                logline("RO_INVALID reason=woke_in_window tid=%d vc_before=%lu vc_after=%lu delta=%lu",
                        g_vic_tid, g_ro_vc0, vc1, vc1 - g_ro_vc0);
            }
        }
    }

    memcpy(after, (const void *)va, REC_BYTES);
    for (i = 0; i < REC_BYTES; i++) if (after[i] != before[i]) diff++;
    memcpy(pg_after, (const void *)page, PAGE);
    for (i = 0; i < (int)PAGE; ) {
        if (pg_after[i] != pg_before[i]) {
            int k = i;
            while (k < (int)PAGE && pg_after[k] != pg_before[k]) k++;
            changed += k - i; runs++;
            if (runs <= 24)
                logline("PAGEMAP run poff=0x%x len=%d before=%02x%02x after=%02x%02x",
                        i, k - i, pg_before[i], pg_before[i + 1], pg_after[i], pg_after[i + 1]);
            i = k;
        } else i++;
    }
    {
        int win64 = 0, lo = (int)apoff - 64, hi = (int)apoff + 64;
        for (i = 0; i < (int)PAGE; i++)
            if (pg_after[i] != pg_before[i] && i >= lo && i <= hi) win64++;
        logline("PAGEMAP page=0x%lx changed_bytes=%d runs=%d ap_poff=0x%lx apwin64_changed=%d",
                page, changed, runs, apoff, win64);
    }
    for (i = 0; i + 32 <= (int)PAGE; i += 8) {
        uint64_t q0, q1, q2, q3; uint32_t lo2;
        memcpy(&q0, pg_after + i, 8); memcpy(&q1, pg_after + i + 8, 8);
        memcpy(&q2, pg_after + i + 16, 8); memcpy(&q3, pg_after + i + 24, 8);
        if (q1 || q3 || !q0) continue;
        lo2 = (uint32_t)(q2 & 0xffffffffu);
        if (lo2 < 0x400u || lo2 > 0x20000u) continue;
        if ((uint32_t)(q2 >> 32) == 0) continue;
        shapes++;
        if (shapes <= 8)
            logline("SHAPE va=0x%lx w0=0x%llx w2=0x%llx poff=0x%lx ip=%u.%u.%u.%u",
                    page + (unsigned long)i, (unsigned long long)q0, (unsigned long long)q2,
                    (unsigned long)i, (unsigned)((q2 >> 32) & 0xff), (unsigned)((q2 >> 40) & 0xff),
                    (unsigned)((q2 >> 48) & 0xff), (unsigned)((q2 >> 56) & 0xff));  /* F5: memory order = network order */
    }
    {   int woke = g_ro_woke; g_ro_woke = 0;
        if (woke) { /* window invalid: not counted */ }
        else if (changed) st_ro_changed++; else st_ro_unchanged++;
        g_ro_woke_flag = woke;
    }
    ro_hex("RO_AFTER", va, after);
    logline("APWIN poff=0x%lx changed_bytes=%d aux_only=1", apoff, diff);
    logline("RO_END idx=%lu mode=%s sec=%d changed_bytes=%d page_changed=%d runs=%d shapes=%d result=%s",
            st_ro_win, g_ro_arm ? "ro" : "rw", sec, diff, changed, runs, shapes,
            g_ro_woke_flag ? "INVALID_WOKE" : (changed ? "CHANGED" : "UNCHANGED"));
}

/* duty as per-mille*10 (5000 = 50.0%) without floating point.  cycles can be 0. */
static unsigned long duty_x10(unsigned long on_us_total, unsigned long cycles)
{
    unsigned long denom;
    if (!cycles) return 0;
    denom = cycles * (cfg_pulse_on + cfg_pulse_off);
    if (!denom) return 0;
    return on_us_total * 10000UL / denom;
}

/* ---- v1.21 pulse window (see ro_victim_window note below for the protocol) ---- */
static void ro_pulse_window(int seq)
{
    unsigned long va = g_ro_req_vap;
    unsigned long page = va & ~(PAGE - 1);
    unsigned long apoff = va & (PAGE - 1);
    unsigned long on_us = cfg_pulse_on, off_us = cfg_pulse_off;
    unsigned long n, t_on_total = 0;
    int rc;

    (void)seq;   /* pulse mode: seq only marks "publish done", the arm runs to duration */
    if (g_ro_vap_first && va != g_ro_vap_first) {
        st_ro_invalid++; g_ro_drift = 1;
        logline("RO_INVALID reason=vap_drift first=0x%lx now=0x%lx D=0x%lx", g_ro_vap_first, va, g_depth);
        g_ro_stop = 1; return;
    }
    if (!g_ro_vap_first) g_ro_vap_first = va;
    if (g_vic_tls_page && page == g_vic_tls_page) {     /* v1.19 PAGE_IS_TLS */
        st_ro_invalid++;
        logline("RO_INVALID reason=ap_on_tls_page page=0x%lx tls_page=0x%lx "
                "note=va_list page IS the thread TCB page => RO impossible", page, g_vic_tls_page);
        g_ro_stop = 1; return;
    }
    if (g_vic_tls_page)
        logline("GUARD_TLS page=0x%lx tls_page=0x%lx same_page=0", page, g_vic_tls_page);
    if (ro_live_guard(page, "helper", read_sp()) != 0) return;

    {   int inst = ro_count_instances(0, 0);        /* census up front */
        if (inst > 0) {
            logline("RO_INVALID reason=multi_instance_pulse count=%d", inst);
            if (g_ro_page) (void)mprotect((void *)g_ro_page, PAGE, PROT_READ | PROT_WRITE);
            g_ro_page = 0; g_pulse_state = 0;
            _exit(4);
        }
    }

    st_ro_win++;
    logline("VAP idx=%lu vap=0x%lx page=0x%lx poff=0x%lx D=0x%lx topminusap=0x%lx mode=pulse "
            "on_us=%lu off_us=%lu loops=%lu helper_sp=0x%lx",
            st_ro_win, va, page, apoff, g_depth,
            (unsigned long)g_rs_top - va, on_us, off_us, cfg_pulse_loops, read_sp());

    g_ro_page = page;                       /* segv()/term handler restore target */
    for (n = 0; !g_ro_stop && !g_ro_abort; n++) {
        unsigned long t0;
        if (cfg_pulse_loops && n >= cfg_pulse_loops) break;
        if (cfg_dur && now_us() >= (unsigned long)cfg_dur * 1000000UL) break;

        {   static unsigned long last_census;   /* re-census every ~60 s (v1.19 rule) */
            unsigned long now = now_us();
            if (n == 0) last_census = now;
            if (now - last_census >= 60000000UL) {
                int inst;
                last_census = now;
                inst = ro_count_instances(0, 0);
                if (inst > 0) {
                    logline("RO_INVALID reason=multi_instance_late count=%d arm=pulse", inst);
                    if (g_ro_page) (void)mprotect((void *)g_ro_page, PAGE, PROT_READ | PROT_WRITE);
                    g_ro_page = 0; g_pulse_state = 0;
                    _exit(4);
                }
            }
        }

        /* --- ON segment: page read-only, victim keeps running --- */
        t0 = now_us();
        rc = mprotect((void *)page, PAGE, PROT_READ);
        if (rc != 0) {
            st_ro_invalid++;
            logline("RO_ERR stage=pulse_mprotect_ro page=0x%lx errno=%d", page, errno);
            g_ro_page = 0; g_ro_stop = 1; return;
        }
        g_pulse_state = 1;
        st_pulse_on++;
        if ((n % 10) == 0)                    /* sample: ~455 pulses/s would flood /data */
            logline("PULSE_ON n=%lu ev=%lu page=0x%lx prot=PROT_READ", n, t0, page);
        {
            for (;;) {
                unsigned long el = now_us() - t0;
                if (el >= on_us) break;
                if (g_ro_abort || g_ro_stop ||
                    (cfg_dur && now_us() >= (unsigned long)cfg_dur * 1000000UL)) break;
                {   struct timespec ts;
                    unsigned long rem = on_us - el;
                    unsigned long sl = rem > 200000UL ? 200000UL : rem;
                    ts.tv_sec = 0; ts.tv_nsec = (long)sl * 1000L;
                    nanosleep(&ts, 0);
                }
            }
            t_on_total += now_us() - t0;
        }
        g_pulse_state = 0;
        rc = mprotect((void *)page, PAGE, PROT_READ | PROT_WRITE);
        if (rc != 0) {
            st_ro_invalid++;
            logline("RO_ERR stage=pulse_mprotect_rw page=0x%lx errno=%d", page, errno);
            g_ro_page = 0; g_ro_stop = 1; return;
        }
        st_pulse_off++;
        if ((n % 10) == 0)
            logline("PULSE_OFF n=%lu ev=%lu page=0x%lx prot=RW on_us=%lu vfault=%lu",
                    n, now_us(), page, now_us() - t0, st_pulse_vfault);

        /* --- OFF segment: page writable (victim self-writes land here) --- */
        {   unsigned long t1 = now_us();
            for (;;) {
                unsigned long el = now_us() - t1;
                if (el >= off_us) break;
                if (g_ro_abort || g_ro_stop ||
                    (cfg_dur && now_us() >= (unsigned long)cfg_dur * 1000000UL)) break;
                {   struct timespec ts;
                    unsigned long rem = off_us - el;
                    unsigned long sl = rem > 200000UL ? 200000UL : rem;
                    ts.tv_sec = 0; ts.tv_nsec = (long)sl * 1000L;
                    nanosleep(&ts, 0);
                }
            }
        }
    }
    /* if the loop broke mid-ON (duration/stop/abort), the page is still RO: restore */
    if (g_pulse_state) {
        (void)mprotect((void *)page, PAGE, PROT_READ | PROT_WRITE);
        g_pulse_state = 0;
        st_pulse_early++;
        logline("PULSE_EARLY_OFF page=0x%lx note=loop_exited_mid_on_restored_rw", page);
    }
    g_ro_page = 0;                            /* page is RW here; safe to clear */
    logline("PULSE_END idx=%lu pulses=%lu on_total_us=%lu duty_x10=%lu vfault=%lu "
            "planned_on_us=%lu note=victim_ran_throughout=1",
            st_ro_win, st_pulse_on, t_on_total,
            duty_x10(t_on_total, n),
            st_pulse_vfault, st_pulse_on * on_us);
}

static void *ro_helper(void *arg)
{
    static unsigned char alt[32 * 1024];
    stack_t hs;
    (void)arg;
    memset(&hs, 0, sizeof hs);
    hs.ss_sp = alt; hs.ss_size = sizeof alt; hs.ss_flags = 0;
    (void)sigaltstack(&hs, 0);
    logline("ALTSTACK who=ro_helper sp=0x%lx size=%lu", (unsigned long)(uintptr_t)alt, (unsigned long)sizeof alt);
    g_ro_helper_up = 1;
    if (cfg_pulse_on) {
        /* pulse arm: wait for the victim's ONE publish, oscillate until duration,
         * then end.  The parked-window request loop below does not apply (the
         * victim never bumps g_ro_req in pulse mode). */
        while (!g_ro_req_vap && !g_ro_helper_end) {
            struct timespec t = {0, 500000L};
            nanosleep(&t, 0);
        }
        if (!g_ro_helper_end && g_ro_req_vap)
            ro_pulse_window(0);
        return 0;
    }
    {
        int seen = 0;
        for (;;) {
            int seq;
            while ((seq = g_ro_req) == seen && !g_ro_helper_end) {
                struct timespec t = {0, 500000L};
                nanosleep(&t, 0);
            }
            if (g_ro_helper_end) break;
            seen = seq;
            ro_do_window(seq);
            g_ro_done = seq;
            ro_futex(FUTEX_WAKE, &g_ro_done, 1);
        }
    }
    return 0;
}

/* ---- victim side: pulse mode publishes and RETURNS (va_list keeps being consumed) ----
 * Parked mode unchanged below.  In pulse mode the victim must NOT block: constraint 1
 * (Phase-1) is that the writer only writes a running victim, so the arm is worthless
 * with the victim parked.  Self-faults during PULSE_ON are recovered by segv()'s
 * siglongjmp (victim-only, altstack), iterated. */
static void ro_victim_window(va_list *app)
{
    if (cfg_ro < 0 || g_ro_stop || !g_ro_helper_up) return;
    if (st_ro_win >= (unsigned long)cfg_ro_loops && !cfg_pulse_on) return;
    if (cfg_pulse_on) {
        /* publish once: the helper oscillates RO/RW for the whole arm */
        if (!g_ro_req_vap) {
            g_ro_req_vap = (unsigned long)(uintptr_t)app;
            g_vic_tls_page = ro_tls_base() & ~(PAGE - 1);   /* v1.19 PAGE_IS_TLS */
            g_ro_arm = 1;
        }
        return;                                   /* victim keeps running */
    }
    g_ro_req_vap = (unsigned long)(uintptr_t)app;
    g_ro_req_sec = cfg_ro_sec;
    g_ro_arm     = cfg_ro;
    g_vic_seq    = (unsigned long)(++g_ro_req);
    g_vic_tls_page = ro_tls_base() & ~(PAGE - 1);   /* v1.19 PAGE_IS_TLS */
    ro_futex(FUTEX_WAKE, &g_ro_req, 1);
    g_vic_waiting = (int)g_vic_seq;                 /* published before blocking */
    /* The loop body must not call any function that could write this frame: the page may
     * become read-only at any moment.  The hard cap is enforced on the helper side
     * (sec+60 s -> restore + _exit(3)); here we only re-check globals. (skeptic F5) */
    while (g_ro_done != (int)g_vic_seq) {
        ro_futex(FUTEX_WAIT, &g_ro_done, g_ro_done);
        if (g_stop || g_ro_abort) {           /* async-signal-safe: restore + _exit */
            if (g_ro_page) (void)mprotect((void *)g_ro_page, PAGE, PROT_READ | PROT_WRITE);
            _exit(3);
        }
    }
    g_vic_waiting = 0;
}

static void ro_shutdown(void)
{
    if (cfg_ro < 0 || !g_ro_helper_up) return;
    g_ro_helper_end = 1;
    g_ro_req++;
    ro_futex(FUTEX_WAKE, &g_ro_req, 1);
    pthread_join(g_ro_thread, 0);
}

static void ro_summary(void)
{
    if (cfg_ro < 0) return;
    if (cfg_pulse_on) {
        logline("RO_SUMMARY mode=pulse windows=%lu pulses_on=%lu pulses_off=%lu vfault=%lu "
                "on_us=%lu off_us=%lu loops=%lu invalid=%lu wb_skipped=%lu vap_first=0x%lx "
                "vap_stable=%d stopped=%d window=helper_stack victim=running",
                st_ro_win, st_pulse_on, st_pulse_off, st_pulse_vfault,
                cfg_pulse_on, cfg_pulse_off, cfg_pulse_loops, st_ro_invalid,
                st_ro_wb_skipped, g_ro_vap_first, (int)(!g_ro_drift), (int)g_ro_stop);
        return;
    }
    logline("RO_SUMMARY mode=%s windows=%lu page_changed=%lu page_unchanged=%lu faults=%lu "
            "invalid=%lu wb_skipped=%lu vap_first=0x%lx vap_stable=%d stopped=%d window=helper_stack",
            cfg_ro ? "ro" : "rw", st_ro_win, st_ro_changed, st_ro_unchanged,
            st_ro_fault, st_ro_invalid, st_ro_wb_skipped, g_ro_vap_first, (int)(!g_ro_drift), (int)g_ro_stop);
    if (cfg_ro == 0 && st_ro_win && !st_ro_changed)
        logline("CTRL_INVALID reason=no_change windows=%lu "
                "note=RW arm never saw a page change => an RO UNCHANGED has no power", st_ro_win);
}

/* variadic wrapper: the live va_list lives here */
static __attribute__((noinline)) void vcall(char *b, size_t bn, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    g_last_ap = (unsigned long)(uintptr_t)&ap;
    ro_victim_window(&ap);
    vsnprintf(b, bn, fmt, ap);
    va_end(ap);
}

/* The 4 bytes at record+0x14..0x17 are the IPv4 address in NETWORK order, i.e.
 * memory bytes b0 b1 b2 b3 spell a.b.c.d.  Read as a little-endian u32 that is
 * 0xb3b2b1b0, so the FIRST octet is the LOW byte.  Getting this backwards
 * silently inverts every private/unicast verdict (lab 2026-11-01: the device's
 * own WAN address was printed byte-reversed and classified as public even
 * though it is the local endpoint). */
#define OCT1(x) ((unsigned)((x) & 0xffu))
#define OCT2(x) ((unsigned)(((x) >> 8) & 0xffu))
#define OCT3(x) ((unsigned)(((x) >> 16) & 0xffu))
#define OCT4(x) ((unsigned)(((x) >> 24) & 0xffu))

static int ip_class(uint32_t be)
{
    unsigned a = OCT1(be), b = OCT2(be);
    if (be == 0) return 0;
    if (a == 0 || a == 255) return 3;
    if (a == 127 || a == 10) return 1;
    if (a == 172 && b >= 16 && b <= 31) return 1;
    if (a == 192 && b == 168) return 1;
    if (a == 169 && b == 254) return 1;
    if (a >= 224) return 3;
    return 2;
}

static int classify(const uint64_t *w, unsigned *rule, uint32_t *lenp, uint32_t *ipp)
{
    uint32_t len, ip;
    unsigned r = 0;
    if (w[1] != 0 || w[3] != 0) return 0;
    if (w[2] == 0) return 0;
    len = (uint32_t)(w[2] & 0xffffffffu);
    ip  = (uint32_t)(w[2] >> 32);
    *lenp = len; *ipp = ip;
    r |= RB_R2;
    if (len >= 0x40 && len <= 0x20000) {
        int c = ip_class(ip);
        if (c == 1 || c == 2) r |= RB_R1;
        if (c == 1) r |= RB_R1L;
    }
    if (w[2] == 0x0109a8c000000641ULL) r |= RB_R3;
    *rule = r;
    return (int)(r & (RB_R1 | RB_R1L | RB_R3));
}

/* --------------------------------------------------------------- patrace PA */
static int patrace_pa(unsigned long va, unsigned long *pa)
{
    char w[48], r[192];
    int fd, n, i;
    if (!cfg_patrace) return -1;
    fd = open(cfg_patrace, O_WRONLY);
    if (fd < 0) return -1;
    n = f_dec(w, (unsigned long)g_pid);
    w[n++] = ' ';
    n = s_cat(w, n, (int)sizeof(w), "0x");
    n += f_hex(w + n, va); w[n] = 0;
    w[n++] = '\n';
    if (write(fd, w, (size_t)n) != n) { close(fd); return -1; }
    close(fd);
    fd = open(cfg_patrace, O_RDONLY);
    if (fd < 0) return -1;
    n = (int)read(fd, r, sizeof(r) - 1);
    close(fd);
    if (n <= 0) return -1;
    r[n] = 0;
    for (i = 0; i + 3 < n; i++)
        if (r[i] == 'p' && r[i+1] == 'a' && r[i+2] == '=') {
            unsigned long v = strtoul(r + i + 3, 0, 16);
            if (v) { *pa = v; return 0; }
            return -1;
        }
    return -1;
}

/* ------------------------------------------------------------------ victim */
static inline unsigned long read_sp(void)
{
#if defined(__aarch64__)
    unsigned long v; __asm__ __volatile__("mov %0, sp" : "=r"(v)); return v;
#elif defined(__x86_64__)
    unsigned long v; __asm__ __volatile__("movq %%rsp, %0" : "=r"(v)); return v;
#else
    return 0;
#endif
}

static void segv(int sig, siginfo_t *si, void *ucp)
{
    ucontext_t *uc = (ucontext_t *)ucp;
    char b[448];
    int n;
    unsigned long pcs = 0, sps = 0, x2 = 0;

    /* v1.25: async-safe breadcrumb -- _exit paths below skip stdio and
     * core_pattern (no NE line); leave a marker on fd 2 instead. */
    if (g_in_handler) { ssize_t rw = write(2, "DYING nested139\n", 16); (void)rw; _exit(139); }
    g_in_handler = 1;
    g_selfcrash++;
#if defined(__aarch64__)
    if (uc) { pcs = (unsigned long)uc->uc_mcontext.pc;
              sps = (unsigned long)uc->uc_mcontext.sp;
              x2  = (unsigned long)uc->uc_mcontext.regs[2]; }
#elif defined(__x86_64__)
    if (uc) { pcs = (unsigned long)uc->uc_mcontext.gregs[REG_RIP];
              sps = (unsigned long)uc->uc_mcontext.gregs[REG_RSP]; }
#endif
    if (g_pulse_state && (unsigned long)(uintptr_t)si->si_addr >= g_ro_page &&
        (unsigned long)(uintptr_t)si->si_addr < g_ro_page + PAGE) {
        /* v1.21 pulse: the victim's own va_list/frame store hit a PULSE_ON segment.
         * EXPECTED by design (the arm keeps the victim running through RO pulses);
         * recovered below by the victim-only siglongjmp.  Log only the first 3 and
         * then 1-in-10000 samples: a hot ON segment can fault thousands of times per
         * second and a per-fault 450 B line would flood /data. */
        st_pulse_vfault++;
        if (st_pulse_vfault <= 3 || (st_pulse_vfault % 10000) == 0)
            logline("PULSE_VFAULT n=%lu addr=0x%lx pc=0x%lx sp=0x%lx note=victim_self_write_recovered",
                    st_pulse_vfault, (unsigned long)(uintptr_t)si->si_addr, pcs, sps);
        g_in_handler = 0;
        if (g_ready && (int)syscall(178) == g_vic_tid) siglongjmp(g_jb, 1);
        _exit(139);
    }
    if (g_ro_page && (unsigned long)(uintptr_t)si->si_addr >= g_ro_page &&
        (unsigned long)(uintptr_t)si->si_addr < g_ro_page + PAGE) {
        st_ro_fault++;
        logline("RO_FAULT addr=0x%lx page=0x%lx pc=0x%lx sp=0x%lx note=a store by THIS process hit the RO page",
                (unsigned long)(uintptr_t)si->si_addr, g_ro_page, pcs, sps);
    }
    n = s_cat(b, 0, (int)sizeof(b), "EV ");
    n += f_dec(b + n, now_us()); b[n] = 0;
    n = f_cat_dec(b, n, (int)sizeof(b), " SELFCRASH sig=", (unsigned long)sig);
    n = f_cat_hex(b, n, (int)sizeof(b), " addr=", (unsigned long)(uintptr_t)si->si_addr);
    n = f_cat_hex(b, n, (int)sizeof(b), " pc=", pcs);
    n = f_cat_hex(b, n, (int)sizeof(b), " sp=", sps);
    n = f_cat_hex(b, n, (int)sizeof(b), " x2=", x2);
    n = f_cat_dec(b, n, (int)sizeof(b), " ep=", (unsigned long)g_epoch);
    n = f_cat_hex(b, n, (int)sizeof(b), " D=", g_depth);
    n = f_cat_dec(b, n, (int)sizeof(b), " n=", (unsigned long)g_selfcrash);
    if (x2 >= (unsigned long)g_rs.base && x2 + 32 <= (unsigned long)g_rs.base + g_rs.size) {
        uint64_t p[4];
        memcpy(p, (const void *)x2, sizeof(p));
        n = f_cat_hex(b, n, (int)sizeof(b), " topminusx2=",
                      (unsigned long)g_rs_top - x2);
        n = s_cat(b, n, (int)sizeof(b), " rec=");
        n += f_hex(b + n, (unsigned long)p[0]); b[n++] = ',';
        n += f_hex(b + n, (unsigned long)p[1]); b[n++] = ',';
        n += f_hex(b + n, (unsigned long)p[2]); b[n++] = ',';
        n += f_hex(b + n, (unsigned long)p[3]); b[n] = 0;
    }
    b[n++] = '\n';
    emit(b, n);
    g_in_handler = 0;
    /* v1.14: only the victim thread may resume at the victim's setjmp point.  A fault on
     * any other thread (scanner / helper / main) that longjmp'ed into g_jb would splice
     * that thread onto the victim's context (UB + silent second crash, which is exactly
     * what the 2026-11-04 00:22 window did). */
    if (g_ready && (int)syscall(178) == g_vic_tid) siglongjmp(g_jb, 1);
    _exit(139);
}

static volatile unsigned long g_pad_sink;
static volatile int g_vpause, g_vpaused;   /* freeze the victim between calls */

/* one variadic call; the caller's pad D shifts every frame below it by D */
/* Sleeping INSIDE the deep frame is a measurement requirement, not a courtesy:
 * at full speed the victim re-spills the same vararg slots ~3e6 times/s, so a
 * 32B record landing in the live frame area is destroyed within ~1 us and a
 * 5 ms scanner can never see it.  That is exactly the t4 self-test failure.
 * --hold-us 0 restores the historical vsurv4 regime (full speed, crash-prone).
 */
/* D14 busy-hold (H6) state: pure user-mode spin inside the deep frame so the
 * victim thread never enters the kernel during its hold.  Calibration runs
 * once at startup; the spin writes only the volatile sink (no stack writes in
 * this frame, no syscalls). */
static volatile unsigned long g_busy_sink;
static unsigned long g_busy_iters;       /* iterations per hold window */

static void hold_sleep(void)
{
    struct timespec t;
    g_last_ts = (unsigned long)(uintptr_t)&t;
    if (!cfg_hold) return;
    if (cfg_hmode == 1) {                 /* D14 busy form: hold the frame WITHOUT entering the kernel */
        unsigned long i = g_busy_iters;
        while (i--) g_busy_sink += i;     /* volatile sink: not optimizable, no stack writes here */
        return;
    }
    t.tv_sec = cfg_hold / 1000000L;
    t.tv_nsec = (cfg_hold % 1000000L) * 1000L;
    nanosleep(&t, 0);
}

/* One-time calibration of the busy-hold spin rate (startup only, before the
 * victim thread exists).  Rough is fine: the arm comparison uses the SAME
 * nominal hold duration, and hold-length jitter of +-20% does not change the
 * "task in kernel vs task in user mode" variable D14 manipulates. */
static void busy_calibrate(void)
{
    unsigned long t0, el, probe = 2000000UL, i;
    if (!cfg_hmode || !cfg_hold) return;
    /* calibrate with the SAME loop shape as the hold loop (volatile sink,
     * no clock read inside): first selftest run on-device showed a clock-read
     * inside the calibration loop skews the rate ~23x low */
    t0 = now_us();
    for (i = 0; i < probe; i++) g_busy_sink += i;
    el = now_us() - t0;
    if (!el) el = 1;
    g_busy_iters = (unsigned long)cfg_hold * probe / el;
    if (!g_busy_iters) g_busy_iters = 1;
    logline("BUSY_CAL probe=%lu el_us=%lu iters_per_us=%lu hold_us=%ld per_hold=%lu",
            probe, el, probe / el, cfg_hold, g_busy_iters);
}

static __attribute__((noinline)) void hot_call(unsigned long d, unsigned long i,
                                               char *b, size_t bn)
{
    if (d) {
        volatile char pad[d];
        pad[0] = (char)i;
        pad[d - 1] = (char)i;
        g_sp_call = read_sp();
        if (cfg_ro >= 0) vcall(b, bn, "%ld", (long)i);
        else             snprintf(b, bn, "%ld", (long)i);
        hold_sleep();
        g_pad_sink = pad[0] + pad[d - 1];            /* keep the pad alive */
    } else {
        g_sp_call = read_sp();
        if (cfg_ro >= 0) vcall(b, bn, "%ld", (long)i);
        else             snprintf(b, bn, "%ld", (long)i);
        hold_sleep();
    }
}

static unsigned long v_iters;    /* file scope: must survive siglongjmp */

static void *victim_main(void *arg)
{
    static unsigned char v_alt[64 * 1024];
    stack_t vss;
    char b[24];
    /* with --ro the snprintf target must NOT live on the guarded page: use the heap */
    char *bp = (cfg_ro >= 0 && g_vbuf) ? (char *)g_vbuf : b;
    size_t bn = (bp == b) ? sizeof(b) : 64;
    unsigned long sp;
    (void)arg;
    memset(&vss, 0, sizeof vss);
    vss.ss_sp = v_alt; vss.ss_size = sizeof v_alt; vss.ss_flags = 0;
    (void)sigaltstack(&vss, 0);   /* PER-THREAD alt stack */
    logline("ALTSTACK who=victim sp=0x%lx size=%lu", (unsigned long)(uintptr_t)v_alt, (unsigned long)sizeof v_alt);
    g_vic_tid = (int)syscall(178);   /* gettid */
    g_victim_up = 1;
    if (cfg_cpu >= 0) {
        cpu_set_t cs;
        CPU_ZERO(&cs); CPU_SET(cfg_cpu, &cs);
        if (sched_setaffinity(0, sizeof cs, &cs) == 0)
            logline("AFFINITY tid=%d want_cpu=%d now_cpu=%d", g_vic_tid, cfg_cpu, sched_getcpu());
        else
            logline("AFFINITY_FAIL tid=%d want_cpu=%d errno=%d", g_vic_tid, cfg_cpu, errno);
    }
    if (cfg_spin) {
        /* U-D1/E3: zero syscalls, zero user stack traffic; only yield (NOP hint). */
        logline("SPIN_START tid=%d zero_syscall=1 note=only_yield", g_vic_tid);
        while (!g_stop) __asm__ __volatile__("yield" ::: "memory");
        logline("SPIN_END tid=%d", g_vic_tid);
        return 0;
    }
    for (;;) {
        if (g_vpause) {
            struct timespec t = {0, 200000};
            g_vpaused = 1;
            while (g_vpause) nanosleep(&t, 0);
            g_vpaused = 0;
        }
        if (sigsetjmp(g_jb, 1) == 0) {
            g_ready = 1;
            if (cfg_calltrace)
                logline("CALL_BEGIN ev=%lu iter=%lu sp=0x%lx", now_us(), v_iters, read_sp());
            hot_call(g_depth, v_iters, bp, bn);
            if (cfg_calltrace)
                logline("CALL_END ev=%lu iter=%lu sp_call=0x%lx", now_us(), v_iters, g_sp_call);
            v_iters++;
            if (!g_frame_logged && (g_last_ap || g_last_ts)) {
                g_frame_logged = 1;
                logline("FRAME ap=0x%lx ts=0x%lx sp_call=0x%lx top=0x%lx",
                        g_last_ap, g_last_ts, g_sp_call, (unsigned long)g_rs_top);
            }
            sp = read_sp();
            if (sp && sp < g_sp_low) g_sp_low = sp;
            g_iters = v_iters;
        } else {
            g_ready = 1;
        }
        if (cfg_idle) {          /* idle OUTSIDE the frame: no va_list in flight */
            struct timespec ti;
            ti.tv_sec = (time_t)(cfg_idle / 1000000UL);
            ti.tv_nsec = (long)(cfg_idle % 1000000UL) * 1000L;
            nanosleep(&ti, 0);
        }
        if (g_stop) break;
    }
    return 0;
}

/* --------------------------------------------------------------- slot table */
static struct slot *slot_find_near(unsigned long va)
{
    int i;
    for (i = 0; i < MAXSLOT; i++) {
        if (!g_slot[i].region) continue;
        {
            long d = (long)g_slot[i].va - (long)va;
            if (d >= -16 && d <= 16) return &g_slot[i];
        }
    }
    return 0;
}
static struct slot *slot_alloc(void)
{
    int i;
    for (i = 0; i < MAXSLOT; i++) if (!g_slot[i].region) return &g_slot[i];
    {
        int best = -1; unsigned long bt = ~0UL;
        for (i = 0; i < MAXSLOT; i++)
            if (g_slot[i].sentineled && g_slot[i].tlast < bt) { bt = g_slot[i].tlast; best = i; }
        if (best >= 0) return &g_slot[best];
    }
    st_overflow++;
    return 0;
}

/* Full context around a hit: does the record sit alone, or is it part of a
 * larger structure?  Copied BEFORE any sentinel write-back (Lead 2026-11-01).
 * Bounded by --ctx so a 450/min hot session cannot flood /data. */
static void emit_ctx(unsigned long va, unsigned long now)
{
    static char *b; static int cap;
    const struct region *r = 0;
    unsigned long lo, hi, a;
    int n, need;

    if (va >= (unsigned long)g_rs.base && va + 32 <= (unsigned long)g_rs.base + g_rs.size) r = &g_rs;
    else if (g_rd.base && va >= (unsigned long)g_rd.base &&
             va + 32 <= (unsigned long)g_rd.base + g_rd.size) r = &g_rd;
    if (!r) return;
    /* U-D1/E2: --ctxbytes 2048 dumps the WHOLE page around the hit (plus margin). */
    lo = va - (unsigned long)cfg_ctxbytes;
    if (lo < (unsigned long)r->base) lo = (unsigned long)r->base;
    hi = va + 32 + (unsigned long)cfg_ctxbytes;
    if (hi > (unsigned long)r->base + r->size) hi = (unsigned long)r->base + r->size;
    need = (int)((hi - lo) * 2) + 512;
    if (need > cap) { char *nb = (char *)realloc(b, (size_t)need); if (!nb) return; b = nb; cap = need; }

    n = s_cat(b, 0, cap, "EV ");
    n += f_dec(b + n, now); b[n] = 0;
    n = s_cat(b, n, cap, " CTX region=");
    n = s_cat(b, n, cap, r == &g_rd ? "decoy" : "stack");
    n = f_cat_hex(b, n, cap, " va=", va);
    n = f_cat_hex(b, n, cap, " topva=", (unsigned long)g_rs_top - va);
    n = f_cat_hex(b, n, cap, " spva=",
                  (g_sp_call > va) ? (g_sp_call - va) : 0);
    n = f_cat_dec(b, n, cap, " ep=", (unsigned long)g_epoch);
    n = f_cat_hex(b, n, cap, " D=", g_depth);
    n = s_cat(b, n, cap, " win=");
    n += f_hex(b + n, lo); b[n++] = '-';
    n += f_hex(b + n, hi); b[n] = 0;
    n = f_cat_dec(b, n, cap, " bytes=", hi - lo);
    n = s_cat(b, n, cap, " hex=");
    for (a = lo; a < hi && n < cap - 3; a++) {
        unsigned char c = *(const volatile unsigned char *)a;
        b[n++] = "0123456789abcdef"[c >> 4];
        b[n++] = "0123456789abcdef"[c & 0xf];
    }
    b[n] = 0;
    emit(b, n);
}

static void slot_emit(struct slot *s, const char *kind, unsigned long now)
{
    unsigned long pa = 0;
    char pa_s[24];
    uint32_t len = 0, ip = 0;
    unsigned dummy = 0;

    if (patrace_pa(s->va, &pa) == 0) {
        int n = s_cat(pa_s, 0, (int)sizeof(pa_s), "0x");
        n += f_hex(pa_s + n, pa); pa_s[n] = 0;
    } else s_cat(pa_s, 0, (int)sizeof(pa_s), "na");

    (void)classify(s->w, &dummy, &len, &ip);

    logline("%s region=%s va=0x%lx page=0x%lx poff=0x%lx topva=0x%lx spva=0x%lx "
            "pa=%s rule=%u ep=%d D=0x%lx w=%lx,%lx,%lx,%lx len=%lu ip=%u.%u.%u.%u "
            "inj=%d sent=%d age_ms=%lu",
            kind, s->region == 1 ? "stack" : "decoy", s->va,
            (s->va & ~(PAGE - 1)), (s->va & (PAGE - 1)),
            (unsigned long)g_rs_top - s->va,
            (g_sp_call > s->va) ? (g_sp_call - s->va) : 0,
            pa_s, s->rule, g_epoch, g_depth,
            (unsigned long)s->w[0], (unsigned long)s->w[1],
            (unsigned long)s->w[2], (unsigned long)s->w[3], (unsigned long)len,
            OCT1(ip), OCT2(ip), OCT3(ip), OCT4(ip),
            s->injected, s->sentineled, (now - s->t0) / 1000);
}

/* --------------------------------------------------------------- scanning   */
static void handle_candidate(unsigned long va, int region, unsigned long now,
                             unsigned rule, int injected)
{
    struct slot *s = slot_find_near(va);
    uint64_t w[4];
    memcpy(w, (const void *)va, sizeof(w));

    if (!s) {
        s = slot_alloc();
        if (!s) return;
        memset(s, 0, sizeof(*s));
        s->va = va; s->region = region;
        s->t0 = now; s->tlast = now; s->rule = rule; s->injected = injected;
        memcpy(s->w, w, sizeof(w));
        st_appear++;
        slot_emit(s, "HIT_APPEAR", now);
    } else if (memcmp(s->w, w, sizeof(w)) != 0) {
        memcpy(s->w, w, sizeof(w));
        s->rule = rule; s->tlast = now; s->va = va;
        if (s->sentineled) {
            st_rewrite++;
            s->sentineled = 0;
            slot_emit(s, "HIT_REWRITE", now);
        } else {
            slot_emit(s, "HIT_CHANGE", now);
        }
    } else {
        s->tlast = now;
        if (now - s->t0 > 10000000UL) {          /* 10 s heartbeat */
            slot_emit(s, "HIT_STAY", now);
            s->t0 = now;
        }
    }
    if (cfg_ctxmax && (long)st_ctx_emitted < cfg_ctxmax) {
        emit_ctx(va, now);
        st_ctx_emitted++;
    } else if (cfg_ctxmax) {
        st_ctx_skipped++;
    }
    /* v1.14: never write a sentinel while a page is read-only -- the scanner does not
     * know about the RO window and its 32 B sentinel store would fault on that page. */
    if (cfg_wb && !s->sentineled && g_ro_page) { st_ro_wb_skipped++; }
    if (cfg_wb && !s->sentineled && !g_ro_page) {
        int may = (region == 2) || (cfg_wb == 2) ||
                  (region == 1 && g_sp_low && va + 32 < g_sp_low);
        if (may) {
            uint64_t sent[4] = { SENT_W0, SENT_W0, SENT_W0, SENT_W0 };
            memcpy((void *)va, sent, sizeof(sent));
            s->sentineled = 1; s->sent_at = now;
            logline("SENTINEL va=0x%lx region=%s residency_ms=%lu",
                    va, region == 1 ? "stack" : "decoy", (s->tlast - s->t0) / 1000);
        }
    }
}

static void scan_region(const struct region *r, int id, unsigned long now)
{
    size_t pos;
    const unsigned char *b = r->base;
    for (pos = 0; pos + REC_BYTES <= r->size; pos += (size_t)cfg_stride) {
        const uint64_t *p = (const uint64_t *)(b + pos);
        uint64_t w0, w1, w2, w3;
        unsigned rule;
        uint32_t len, ip;
        int inj;
        w1 = p[1];
        if (w1 != 0) continue;
        w3 = p[3];
        if (w3 != 0) continue;
        w2 = p[2];
        if (w2 == 0) continue;
        w0 = p[0];
        st_cand++;
        {
            uint64_t wv[4]; wv[0] = w0; wv[1] = w1; wv[2] = w2; wv[3] = w3;
            if (!classify(wv, &rule, &len, &ip)) { st_r2only++; continue; }
        }
        inj = (w0 == INJ_W0);
        if (cfg_logrule == 0 && !(rule & RB_R2)) continue;
        if (cfg_logrule == 2 && !(rule & RB_R3)) continue;
        handle_candidate((unsigned long)p, id, now, rule, inj);
    }
}

static void scan_pass(void)
{
    unsigned long t = now_us(), dt;
    scan_region(&g_rs, 1, t);
    if (g_rd.base) scan_region(&g_rd, 2, t);
    dt = now_us() - t;
    st_pass++;
    st_bytes += g_rs.size + (g_rd.base ? g_rd.size : 0);
    st_scan_us_sum += dt;
    if (dt > st_scan_us_max) st_scan_us_max = dt;
}

static void age_slots(unsigned long now)
{
    int i;
    for (i = 0; i < MAXSLOT; i++) {
        struct slot *s = &g_slot[i];
        if (!s->region) continue;
        if (s->sentineled) {
            if (now - s->sent_at > 5000000UL) { st_rewrite_none++; s->sentineled = 0; }
            continue;
        }
        if (now - s->tlast > 200000UL) {
            logline("HIT_GONE va=0x%lx region=%s residency_ms=%lu ep=%d D=0x%lx",
                    s->va, s->region == 1 ? "stack" : "decoy",
                    (s->tlast - s->t0) / 1000, g_epoch, g_depth);
            s->region = 0;
        }
    }
}

/* ------------------------------------------------------------- self-checks  */
static void inject_record(unsigned char *dst)
{
    uint64_t w[4];
    w[0] = INJ_W0; w[1] = 0; w[2] = 0x0109a8c000000641ULL; w[3] = 0;
    memcpy(dst, w, REC_BYTES);
}
static int find_va(unsigned long va) { return slot_find_near(va) != 0; }
static void drop_va(unsigned long va) { struct slot *s = slot_find_near(va); if (s) memset(s, 0, sizeof(*s)); }

static int selftest(void)
{
    unsigned char *sd, *ss, *neg, *hot;
    unsigned long vd, vs, vn, vh;
    int ok = 1;

    sd  = g_rd.base + PAGE + 0x800;                  /* decoy, 16B aligned       */
    ss  = g_rs.base + g_rs.size - (256UL << 10);     /* stack, pre-poisoned area */
    neg = g_rd.base + PAGE + 0x900;
    hot = (unsigned char *)(g_rs_top - 0x390);       /* historical landing zone  */
    vd = (unsigned long)sd; vs = (unsigned long)ss;
    vn = (unsigned long)neg; vh = (unsigned long)hot;

    inject_record(sd); scan_pass();
    if (!find_va(vd)) { logline("SELFTEST_FAIL t1_decoy va=0x%lx", vd); ok = 0; }
    else logline("SELFTEST_OK t1_decoy va=0x%lx", vd);

    if (!g_rs_heap) memset((void *)vs, 0, 64);
    inject_record(ss); scan_pass();
    if (!find_va(vs)) { logline("SELFTEST_FAIL t2_stack va=0x%lx", vs); ok = 0; }
    else logline("SELFTEST_OK t2_stack va=0x%lx", vs);

    { uint64_t bad[4] = { 0x1234, 0x1111, 0x0109a8c000000641ULL, 0 };
      memcpy(neg, bad, REC_BYTES); }
    scan_pass();
    if (find_va(vn)) { logline("SELFTEST_FAIL t3_negative va=0x%lx", vn); ok = 0; }
    else logline("SELFTEST_OK t3_negative va=0x%lx", vn);

    /* T4: the historical hot slot.  This one sits INSIDE the live frame area, so
     * the victim overwrites it within a few ms; freeze the victim around the
     * injection or the test measures the harness, not the matcher. */
    {
        unsigned char save[REC_BYTES];
        int paused = 0;
        if (g_victim_up) {
            int w = 0;
            g_vpause = 1;
            while (!g_vpaused && w++ < 200) {
                struct timespec t = {0, 1000000};
                nanosleep(&t, 0);
            }
            paused = g_vpaused;
        }
        memcpy(save, hot, REC_BYTES);
        inject_record(hot);
        scan_pass();
        if (!find_va(vh)) scan_pass();
        if (!find_va(vh)) {
            logline("SELFTEST_SKIP t4_hotslot va=0x%lx paused=%d race=1", vh, paused);
        } else {
            logline("SELFTEST_OK t4_hotslot va=0x%lx paused=%d", vh, paused);
        }
        memcpy(hot, save, REC_BYTES);
        drop_va(vh);
        if (paused) { g_vpause = 0; while (g_vpaused) { struct timespec t = {0, 100000}; nanosleep(&t, 0); } }
    }

    memset(sd, 0x5a, 64); memset(neg, 0x5a, 64);
    if (g_rs_heap) memset(ss, 0x5a, 64); else memset(ss, 0, 64);
    drop_va(vd); drop_va(vs); drop_va(vn);
    scan_pass();

    if (ok) st_selft_ok++; else st_selft_bad++;
    return ok;
}

static void probe_decoy(unsigned long now)
{
    static unsigned idx;
    unsigned char *p = g_rd.base + PAGE + ((idx % 64) * 64);
    unsigned long va = (unsigned long)p;
    int i, found = 0;
    idx++;
    inject_record(p);
    for (i = 0; i < 4; i++) { scan_pass(); if (find_va(va)) { found = 1; break; } }
    memset(p, 0x5a, 64);
    drop_va(va);
    if (found) { st_probe_ok++; logline("PROBE ok=1 va=0x%lx", va); }
    else { st_probe_bad++; logline("PROBE ok=0 va=0x%lx", va); }
    (void)now;
}

/* ---------------------------------------------------------------- scanner   */
static unsigned long g_epoch_start;

static void epoch_tick(unsigned long t)
{
    if (!cfg_epoch || cfg_ndepth < 2) return;
    if (g_epoch_idx + 1 >= cfg_ndepth) {
        if (!cfg_cycle) return;
    }
    if (t - g_epoch_start < (unsigned long)cfg_epoch * 1000000UL) return;
    g_epoch_start = t;
    logline("EPOCH_END n=%d D=0x%lx iters=%lu topminussp=0x%lx sp_call=0x%lx",
            g_epoch, g_depth, g_iters,
            (unsigned long)(g_rs_top - (unsigned char *)g_sp_call),
            (unsigned long)g_sp_call);
    g_epoch_idx++;
    if (g_epoch_idx >= cfg_ndepth) g_epoch_idx = 0;         /* --cycle wraps */
    g_depth = cfg_depths[g_epoch_idx];
    g_epoch = g_epoch_idx;
    logline("EPOCH_BEGIN n=%d D=0x%lx", g_epoch, g_depth);
}

static void stat_tick(unsigned long t)
{
    static unsigned long last;
    if (t - last < 60000000UL) return;
    last = t;
    logline("STAT passes=%lu cand=%lu r2only=%lu appear=%lu rewrite=%lu "
            "rewrite_none=%lu overflow=%lu selfcrash=%lu probe_ok=%lu "
            "probe_bad=%lu scan_us_avg=%lu scan_us_max=%lu iters=%lu "
            "ctx=%lu ctx_skip=%lu "
            "ep=%d D=0x%lx topminussp=0x%lx",
            st_pass, st_cand, st_r2only, st_appear, st_rewrite,
            st_rewrite_none, st_overflow, g_selfcrash, st_probe_ok,
            st_probe_bad, st_pass ? st_scan_us_sum / st_pass : 0,
            st_scan_us_max, g_iters, st_ctx_emitted, st_ctx_skipped,
            g_epoch, g_depth,
            (unsigned long)(g_rs_top - (unsigned char *)g_sp_call));
}

static void *scanner_main(void *arg)
{
    unsigned long next_probe = (unsigned long)cfg_probe * 1000000UL;
    unsigned long next_churn = (unsigned long)cfg_churn * 1000000UL;
    (void)arg;
    while (!g_stop) {
        unsigned long t = now_us();
        scan_pass();
        age_slots(now_us());
        epoch_tick(t);
        stat_tick(t);
        if (cfg_dur && t >= (unsigned long)cfg_dur * 1000000UL) { g_stop = 1; }
        if (cfg_probe && t >= next_probe) { probe_decoy(t); next_probe = t + (unsigned long)cfg_probe * 1000000UL; }
        if (cfg_churn && g_rd.base && t >= next_churn) {
            unsigned long i;
            for (i = 0; i < MAXSLOT; i++)
                if (g_slot[i].region == 2) memset(&g_slot[i], 0, sizeof(g_slot[i]));
            munmap(g_rd.base, g_rd.size);
            g_rd.base = mmap(0, g_rd.size, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (g_rd.base != MAP_FAILED) {
                size_t k; uint64_t *q = (uint64_t *)g_rd.base;
                for (k = 0; k < g_rd.size / 8; k++) q[k] = POISON;
                logline("CHURN decoy=0x%lx", (unsigned long)g_rd.base);
            } else { g_rd.base = 0; logline("CHURN_FAIL errno=%d", errno); }
            next_churn = t + (unsigned long)cfg_churn * 1000000UL;
        }
        {
            unsigned long el = now_us() - t;
            if (el < (unsigned long)cfg_period) {
                struct timespec ts;
                unsigned long sl = (unsigned long)cfg_period - el;
                ts.tv_sec = 0; ts.tv_nsec = (long)sl * 1000L;
                nanosleep(&ts, 0);
            }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------- main   */
static void on_term(int s) { (void)s; g_stop = 1; }

static void usage(void)
{
    printf(VERSION "\n"
        "  --stack BYTES      private stack size / main-stack window (default 2M)\n"
        "  --decoy BYTES      decoy mapping size (default 8M)\n"
        "  --period-us N      scan period, <=10000 (default 5000)\n"
        "  --hold-us N        us the victim sleeps INSIDE its deep frame (default 10000;\n"
        "                     0 = full speed = the historical vsurv4 crash regime)\n"
        "  --hold-mode M      sleep|busy  how the deep frame is held (default sleep).\n"
        "                     busy = pure user-mode spin, no syscall during hold (D14/H6)\n"
        "  --stride N         scan stride 8 or 16 (default 16)\n"
        "  --writeback M      none|safe|all (default safe)\n"
        "  --victim M         pthread|main   (default pthread)\n"
        "  --depth-list L     e.g. 0,0x100,0x400,0x900,0x1000\n"
        "  --epoch-sec N      seconds per depth epoch (default 60)\n"
        "  --cycle 0|1        wrap the depth list until --duration (default 0)\n"
        "  --duration S       seconds, 0=forever (default 0)\n"
        "  --log PATH         log file\n"
        "  --patrace PATH     /proc/patrace for VA->PA (optional)\n"
        "  --probe-sec N      liveness probe period, 0=off (default 120)\n"
        "  --churn-sec N      re-map the decoy every N s, 0=off\n"
        "  --ctx N            full 32B +/-256B context dumps, 0=off (default 200)\n"
        "  --ctxbytes N       U-D1/E2: context half-window bytes (default 256)\n"
        "  --spin 0|1         U-D1/E3: victim spins with yield only, zero syscalls\n"
        "  --cpu N            U-D1/E4: pin the victim thread to CPU N\n"
        "  --log-rule r       r1|r2|r3 (default r1)\n"
        "  --selftest 0|1     matcher self-test (default 1)\n"
        "  --idle-us N        sleep N us between calls, OUTSIDE the frame (time-correlation arm)\n"
        "  --calltrace 0|1     log CALL_BEGIN/CALL_END around every call (default 0)\n"
        "  --ro 0|1           1 = read-only arm on the LIVE va_list page (&ap),\n"
        "                     0 = RW control arm (same cadence, no mprotect)\n"
        "  --ro-sec S         hold/dump window seconds (default 1)\n"
        "  --ro-loops N       number of windows (default 1; RW arm counts changes)\n"
        "  --pulse ON_US,OFF_US v1.21 pulse arm: mprotect RO for ON_US, RW for OFF_US,\n"
        "                     (MICROseconds), repeated, while the victim KEEPS RUNNING\n"
        "                     (Phase-2a: DMA vs CPU).  ON_US in [500,2000] enforced;\n"
        "                     implies --ro 1 (typical: --pulse 1000,1000 = 1ms/1ms)\n"
        "  --pulse-loops N    stop after N pulses (0 = until --duration, default 0)\n");
}

static size_t parse_size(const char *s)
{
    char *e; unsigned long v = strtoul(s, &e, 0);
    if (*e == 'k' || *e == 'K') v <<= 10;
    else if (*e == 'm' || *e == 'M') v <<= 20;
    else if (*e == 'g' || *e == 'G') v <<= 30;
    return (size_t)v;
}

static unsigned long read_startstack(void)
{
    char b[512];
    int f = open("/proc/self/stat", O_RDONLY), n, i, fld = 0;
    unsigned long v = 0;
    if (f < 0) return 0;
    n = (int)read(f, b, sizeof(b) - 1);
    close(f);
    if (n <= 0) return 0;
    b[n] = 0;
    for (i = 0; i < n; i++) if (b[i] == ')') { i++; break; }
    for (; i < n; i++)
        if (b[i] == ' ') { fld++; if (fld == 26) { v = strtoul(b + i + 1, 0, 10); break; } }
    return v;
}

int main(int argc, char **argv)
{
    int i;
    struct sigaction sa;
    stack_t ss;
    pthread_attr_t at;
    pthread_t sc;

    /* v1.25 (U-F1): unbuffered stdout so a mid-session death never swallows the
     * log (2026-11-04 23:4x incident: silent death, 98-byte log; musl does not
     * honour _IOLBF flushes on non-tty files). */
    setvbuf(stdout, NULL, _IONBF, 0);

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : 0;
        if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(); return 0; }
        else if (!strcmp(a, "--stack")    && v) { cfg_stack  = parse_size(v); i++; }
        else if (!strcmp(a, "--decoy")    && v) { cfg_decoy  = parse_size(v); i++; }
        else if (!strcmp(a, "--period-us")&& v) { cfg_period = atol(v); i++; }
        else if (!strcmp(a, "--hold-us")  && v) { cfg_hold   = atol(v); i++; }
        else if (!strcmp(a, "--hold-mode")&& v) { cfg_hmode  = !strcmp(v, "busy") ? 1 : 0; i++; }
        else if (!strcmp(a, "--ctx")      && v) { cfg_ctxmax = atol(v); i++; }
        else if (!strcmp(a, "--ctxbytes") && v) { cfg_ctxbytes = atol(v); i++; }
        else if (!strcmp(a, "--spin")     && v) { cfg_spin   = atoi(v); i++; }
        else if (!strcmp(a, "--cpu")      && v) { cfg_cpu    = atoi(v); i++; }
        else if (!strcmp(a, "--stride")   && v) { cfg_stride = atoi(v); i++; }
        else if (!strcmp(a, "--duration") && v) { cfg_dur    = atoi(v); i++; }
        else if (!strcmp(a, "--log")      && v) { cfg_log    = v; i++; }
        else if (!strcmp(a, "--patrace")  && v) { cfg_patrace= v; i++; }
        else if (!strcmp(a, "--probe-sec")&& v) { cfg_probe  = atoi(v); i++; }
        else if (!strcmp(a, "--churn-sec")&& v) { cfg_churn  = atoi(v); i++; }
        else if (!strcmp(a, "--selftest") && v) { cfg_selft  = atoi(v); i++; }
        else if (!strcmp(a, "--epoch-sec")&& v) { cfg_epoch  = atoi(v); i++; }
        else if (!strcmp(a, "--cycle")    && v) { cfg_cycle  = atoi(v); i++; }
        else if (!strcmp(a, "--victim")   && v) { cfg_main   = !strcmp(v, "main"); i++; }
        else if (!strcmp(a, "--depth-list") && v) {
            const char *p = v; cfg_ndepth = 0;
            while (*p && cfg_ndepth < MAXDEPTH) {
                cfg_depths[cfg_ndepth++] = strtoul(p, (char **)&p, 0);
                if (*p == ',') p++;
            }
            i++;
        }
        else if (!strcmp(a, "--writeback")&& v) {
            if (!strcmp(v, "none")) cfg_wb = 0;
            else if (!strcmp(v, "all")) cfg_wb = 2;
            else cfg_wb = 1;
            i++;
        }
        else if (!strcmp(a, "--log-rule") && v) {
            if (!strcmp(v, "r2")) cfg_logrule = 0;
            else if (!strcmp(v, "r3")) cfg_logrule = 2;
            else cfg_logrule = 1;
            i++;
        }
        else if (!strcmp(a, "--idle-us")   && v) { cfg_idle      = strtoul(v, 0, 0); i++; }
        else if (!strcmp(a, "--calltrace") && v) { cfg_calltrace = atoi(v); i++; }
        else if (!strcmp(a, "--ro")       && v) { cfg_ro      = atoi(v); i++; }
        else if (!strcmp(a, "--ro-sec")   && v) { cfg_ro_sec  = atoi(v); i++; }
        else if (!strcmp(a, "--ro-loops") && v) { cfg_ro_loops= atoi(v); i++; }
        else if (!strcmp(a, "--pulse")    && v) {
            char *e;
            cfg_pulse_on  = strtoul(v, &e, 0);
            if (*e != ',') { fprintf(stderr, "--pulse needs ON_MS,OFF_MS\n"); return 2; }
            cfg_pulse_off = strtoul(e + 1, &e, 0);
            if (cfg_pulse_on < 500 || cfg_pulse_on > 2000) {
                fprintf(stderr, "--pulse ON_MS out of [500,2000] us (guard band vs "
                        "self-fault storm / coverage)\n"); return 2;
            }
            if (!cfg_pulse_off) { fprintf(stderr, "--pulse OFF_MS must be > 0\n"); return 2; }
            i++;
        }
        else if (!strcmp(a, "--pulse-loops") && v) { cfg_pulse_loops = strtoul(v, 0, 0); i++; }
        else { fprintf(stderr, "unknown arg %s\n", a); usage(); return 2; }
    }
    if (cfg_pulse_on) {
        if (cfg_ro >= 0) {
            fprintf(stderr, "--pulse is incompatible with --ro (pulse implies its own RO arm)\n");
            return 2;
        }
        cfg_ro = 1;      /* reuse all the --ro machinery: guards, helper, term handler */
        cfg_ro_loops = 1;
    }
    if (cfg_ro >= 0) {
        if (cfg_ro_sec <= 0) cfg_ro_sec = 1;
        if (cfg_ro_loops <= 0) cfg_ro_loops = 1;
        if (cfg_hold)
            fprintf(stderr, "note: --ro adds its own %d s hold inside the va_list frame; --hold-us %ld still applies after it\n",
                    cfg_ro_sec, cfg_hold);
        g_vbuf = (unsigned char *)malloc(64);
        if (!g_vbuf) { fprintf(stderr, "malloc for --ro buffer failed\n"); return 2; }
    }
    if (cfg_period <= 0) cfg_period = 5000;
    if (cfg_period > 10000) { fprintf(stderr, "period clamped to 10000us\n"); cfg_period = 10000; }
    if (cfg_stride != 8 && cfg_stride != 16) cfg_stride = 16;
    if (cfg_stack < (256UL << 10)) cfg_stack = 256UL << 10;
    if (cfg_decoy < PAGE) cfg_decoy = PAGE;
    if (cfg_ndepth < 1) { cfg_depths[0] = 0; cfg_ndepth = 1; }
    if (cfg_epoch <= 0) cfg_epoch = 3600;
    if (cfg_hmode && !cfg_hold) {
        fprintf(stderr, "--hold-mode busy requires --hold-us > 0 (full speed has no hold)\n");
        return 2;
    }

    g_pid = (int)getpid();
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        g_t0_us = (unsigned long)(ts.tv_sec * 1000000UL + ts.tv_nsec / 1000UL);
    }
    g_logfd = open(cfg_log, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_logfd < 0) { fprintf(stderr, "cannot open %s: %d\n", cfg_log, errno); return 2; }
    {   /* U-D1/E5: wall-clock anchor for tcpdump correlation (no epoch arithmetic). */
        struct timeval tv;
        gettimeofday(&tv, 0);
        logline("T0 epoch_us=%lld mono0_us=%lu pid=%d",
                (long long)tv.tv_sec * 1000000LL + (long long)tv.tv_usec, g_t0_us, g_pid);
    }

    if (cfg_hmode) busy_calibrate();   /* D14: after g_t0_us/logfd, before any thread */

    /* --- RO arm setup (v1.11): hard precondition + helper thread on its own stack --- */
    if (cfg_ro >= 0) {
        /* Precondition (v1.16): ONE FIXED depth, no cycling.  The original rule also
         * forced D==0, but at D==0 the live va_list sits in the thread's TOP page, and
         * musl keeps the thread's TCB/TLS there -- any errno/TLS access in the victim
         * touches that page, so an RO window can never survive it (field 2026-11-04:
         * fault address constant at top-0xd8, i.e. inside the TCB).  A fixed D != 0 moves
         * &ap one page (or more) down, off the TCB page, while keeping the depth constant
         * for the whole arm -- which is what "one fixed frame depth" actually requires. */
        if (cfg_ndepth != 1 || cfg_cycle) {
            logline("RO_INVALID reason=depth_list_not_single ndepth=%d cycle=%d "
                    "note=need exactly one depth and --cycle 0", cfg_ndepth, cfg_cycle);
            fprintf(stderr, "RO_INVALID reason=depth_list_not_single (need one depth, --cycle 0)\n");
            return 2;
        }
        logline("RO_DEPTH fixed D=0x%lx note=D!=0 keeps &ap off the TCB page (top page)", cfg_depths[0]);
        {   char own[64] = "?";
            g_ro_inst = ro_count_instances(own, sizeof own);
            logline("INSTANCES comm=%s count=%d self=%d rule=exact_comm_excl_self", own, g_ro_inst, (int)getpid());
            if (g_ro_inst > 0) {          /* F2: count EXCLUDES self => >0 means another instance */
                logline("RO_INVALID reason=multi_instance comm=%s count=%d", own, g_ro_inst);
                fprintf(stderr, "RO_INVALID reason=multi_instance count=%d\n", g_ro_inst);
                return 2;
            }
        }
        g_ro_stack = (unsigned char *)mmap(0, RO_STACK_BYTES + RO_STACK_GAP, PROT_READ | PROT_WRITE,
                                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (g_ro_stack == MAP_FAILED) { fprintf(stderr, "RO helper stack mmap failed\n"); return 2; }
        mprotect(g_ro_stack, RO_STACK_GAP, PROT_NONE);   /* hard gap: PROT_NONE, never usable */
        {
            pthread_attr_t roat;
            pthread_attr_init(&roat);
            if (pthread_attr_setstack(&roat, g_ro_stack + RO_STACK_GAP, RO_STACK_BYTES) != 0) {
                fprintf(stderr, "pthread_attr_setstack(helper) failed\n"); return 2;
            }
            if (pthread_create(&g_ro_thread, &roat, ro_helper, 0) != 0) {
                fprintf(stderr, "RO helper pthread_create failed\n"); return 2;
            }
        }
        {   struct timespec t = {0, 1000000}; int w = 0;
            while (!g_ro_helper_up && w++ < 2000) nanosleep(&t, 0); }
        if (!g_ro_helper_up) { fprintf(stderr, "RO helper did not come up\n"); return 2; }
        {   struct sigaction ta;
            memset(&ta, 0, sizeof ta);
            ta.sa_handler = on_term_win;
            ta.sa_flags = SA_ONSTACK;      /* F1: handler frame must NOT land on the RO page */
            sigemptyset(&ta.sa_mask);
            {   /* the launching shell may have SIGTERM/SIGINT blocked (inherited mask) --
                 * unblock them so "kill <pid>" is honoured promptly, including mid-window */
                sigset_t ub;
                sigemptyset(&ub); sigaddset(&ub, SIGTERM); sigaddset(&ub, SIGINT);
                (void)sigprocmask(SIG_UNBLOCK, &ub, 0);
            }
            (void)sigaction(SIGTERM, &ta, 0);
            (void)sigaction(SIGINT,  &ta, 0);
        }
        logline("RO_SETUP mode=%s sec=%d loops=%d helper_stack=0x%lx gap=%lu precondition=depth_list_0 ok "
                "safety=term_restore+hard_cap_%ds%s",
                cfg_pulse_on ? "pulse" : (cfg_ro ? "ro" : "rw"), cfg_ro_sec, cfg_ro_loops,
                (unsigned long)(g_ro_stack + RO_STACK_GAP), (unsigned long)RO_STACK_GAP, cfg_ro_sec + 60,
                cfg_pulse_on ? " pulse=1mson_1msoff_typ" : "");
    }

    /* --- victim stack ------------------------------------------------------ */
    if (cfg_main) {
        unsigned long top = read_startstack();
        if (!top) { fprintf(stderr, "cannot read start_stack\n"); return 2; }
        g_rs_top = (unsigned char *)top;
        g_rs.base = (unsigned char *)(top - cfg_stack);
        g_rs.size = cfg_stack;
        g_rs.name = "mainstack";
        g_rs_heap = 0;
    } else {
        g_rs.base = mmap(0, cfg_stack, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (g_rs.base == MAP_FAILED) { fprintf(stderr, "stack mmap failed\n"); return 2; }
        g_rs.size = cfg_stack; g_rs.name = "stack"; g_rs_heap = 1;
        g_rs_top = g_rs.base + cfg_stack;
        { uint64_t *q = (uint64_t *)g_rs.base; size_t k;
          for (k = 0; k < cfg_stack / 8; k++) q[k] = POISON; }
    }

    /* --- decoy ------------------------------------------------------------- */
    g_rd.base = mmap(0, cfg_decoy, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g_rd.base == MAP_FAILED) { fprintf(stderr, "decoy mmap failed\n"); return 2; }
    g_rd.name = "decoy"; g_rd.size = cfg_decoy;
    { uint64_t *q = (uint64_t *)g_rd.base; size_t k;
      for (k = 0; k < cfg_decoy / 8; k++) q[k] = POISON; }

    logline("START %s pid=%d victim=%s stack=0x%lx/%lu top=0x%lx decoy=0x%lx/%lu "
            "period_us=%ld hold_us=%ld hmode=%d stride=%d wb=%d probe=%d churn=%d epoch_sec=%d ndepth=%d cycle=%d "
            "logrule=%d patrace=%s instances=%d rules=R2(loose)|R1(w1==0&&w3==0&&len[0x40,0x20000]"
            "&&ip-unicast)|R1L(+private)|R3(w2==0x0109a8c000000641)",
            VERSION, g_pid, cfg_main ? "main" : "pthread",

            (unsigned long)g_rs.base, (unsigned long)g_rs.size, (unsigned long)g_rs_top,
            (unsigned long)g_rd.base, (unsigned long)cfg_decoy,
            cfg_period, cfg_hold, cfg_hmode, cfg_stride, cfg_wb, cfg_probe, cfg_churn, cfg_epoch,
            cfg_ndepth, cfg_cycle, cfg_logrule, cfg_patrace ? cfg_patrace : "none", g_ro_inst);
    if (cfg_ro >= 0)
        logline("RO_START mode=%s sec=%d loops=%d victim=%s hold_us=%ld hmode=%d "
                "target=live_vap_page(C-171) not=start_stack-0x390%s",
                cfg_pulse_on ? "pulse" : (cfg_ro ? "ro" : "rw"), cfg_ro_sec, cfg_ro_loops,
                cfg_main ? "main" : "pthread", cfg_hold, cfg_hmode,
                cfg_pulse_on ? " pulse_on_us=.. pulse_off_us=.. note=victim_running" : "");
    if (cfg_pulse_on) {
        /* overwrite the generic line with the full pulse parameters */
        logline("PULSE_START on_us=%lu off_us=%lu loops=%lu duty=%.1f%% victim=running "
                "note=self_faults_recovered_by_longjmp expected",
                cfg_pulse_on, cfg_pulse_off, cfg_pulse_loops,
                (double)(100.0 * cfg_pulse_on / (cfg_pulse_on + cfg_pulse_off)));
    }

    /* --- signals ---------------------------------------------------------- */
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = g_altstack; ss.ss_size = sizeof(g_altstack); ss.ss_flags = 0;
    (void)sigaltstack(&ss, 0);
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = segv; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, 0);
    sigaction(SIGBUS, &sa, 0);
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_term;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, 0);
    sigaction(SIGINT, &sa, 0);

    /* v1.18: the generic block above just REPLACED any earlier RO gate handler, so install
     * the window gate AFTER it.  on_term_win restores the page to RW and _exit(3), which is
     * what makes "kill <pid>" work INSIDE an RO window (async-signal-safe: mprotect+_exit). */
    if (cfg_ro >= 0) {
        struct sigaction ta;
        memset(&ta, 0, sizeof ta);
        ta.sa_handler = on_term_win;
        ta.sa_flags = SA_ONSTACK;       /* handler frame must not land on the RO page */
        sigemptyset(&ta.sa_mask);
        (void)sigaction(SIGTERM, &ta, 0);
        (void)sigaction(SIGINT, &ta, 0);
    }

    /* --- victim ------------------------------------------------------------ */
    g_depth = cfg_depths[0];
    if (!cfg_main) {
        pthread_attr_init(&at);
        pthread_attr_setstack(&at, g_rs.base, cfg_stack);
        if (pthread_create(&g_victim, &at, victim_main, 0)) {
            fprintf(stderr, "pthread_create failed\n"); return 2;
        }
        while (!g_victim_up) { struct timespec t = {0, 1000000}; nanosleep(&t, 0); }
    }

    /* --- mandatory self-test (fail-closed) -------------------------------- */
    if (cfg_selft) {
        if (!selftest()) {
            logline("EXIT reason=selftest_fail");
            fprintf(stderr, "SELFTEST FAILED\n");
            return 2;
        }
    }
    logline("SELFTEST_PASS scans=%lu sp_call=0x%lx topminussp=0x%lx",
            st_pass, (unsigned long)g_sp_call,
            (unsigned long)(g_rs_top - (unsigned char *)g_sp_call));

    /* --- scanner thread --------------------------------------------------- */
    if (pthread_create(&sc, 0, scanner_main, 0)) {
        fprintf(stderr, "scanner pthread_create failed\n"); return 2;
    }
    g_epoch_start = now_us();
    logline("EPOCH_BEGIN n=0 D=0x%lx epoch_sec=%d", g_depth, cfg_epoch);

    if (cfg_main) {
        /* the victim is this very thread; the scanner thread owns the clocks */
        victim_main(0);
    } else {
        while (!g_stop) {
            struct timespec t = {0, 100L * 1000 * 1000};
            nanosleep(&t, 0);
        }
    }

    g_stop = 1;
    pthread_join(sc, 0);
    ro_shutdown();
    ro_summary();
    logline("EXIT reason=duration passes=%lu appear=%lu rewrite=%lu rewrite_none=%lu "
            "selfcrash=%lu probe_ok=%lu probe_bad=%lu overflow=%lu selftest_ok=%lu "
            "selftest_bad=%lu iters=%lu scan_us_avg=%lu scan_us_max=%lu pulse_vfault=%lu pulses_on=%lu",
            st_pass, st_appear, st_rewrite, st_rewrite_none, g_selfcrash,
            st_probe_ok, st_probe_bad, st_overflow, st_selft_ok, st_selft_bad,
            g_iters, st_pass ? st_scan_us_sum / st_pass : 0, st_scan_us_max,
            st_pulse_vfault, st_pulse_on);
    if (g_logfd >= 0) close(g_logfd);
    return 0;
}
