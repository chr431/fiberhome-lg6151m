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
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

#define VERSION    "scanary-1.4"
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
static int    cfg_migsec = 0;          /* U-G3: periodic MADV_DONTNEED of hot-slot page */
static unsigned long cfg_migva;        /* explicit va, else last-hit slot */
static int    cfg_logrule= 1;           /* 0 R2 | 1 R1 | 2 R3 | 3 all         */
static long   cfg_ctxmax = 200;         /* full 32B+/-256B context dumps, 0=off */
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

/* The 4 bytes at record+0x14..0x17 are the IPv4 address in NETWORK order, i.e.
 * memory bytes b0 b1 b2 b3 spell a.b.c.d.  Read as a little-endian u32 that is
 * 0xb3b2b1b0, so the FIRST octet is the LOW byte.  Getting this backwards
 * silently inverts every private/unicast verdict (lab 2026-11-01: the device's
 * own WAN address 110.65.xx.28 was printed as 28.40.65.110 and classified as
 * public even though it is the local endpoint). */
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

    if (g_in_handler) _exit(139);
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
    if (g_ready) siglongjmp(g_jb, 1);
    _exit(139);
}

static volatile unsigned long g_pad_sink;
static volatile int g_vpause, g_vpaused;   /* freeze the victim between calls */
static volatile unsigned long g_last_hit_va; /* U-G3 */
static volatile unsigned long g_last_hit_va; /* U-G3 */

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
        snprintf(b, bn, "%ld", (long)i);
        hold_sleep();
        g_pad_sink = pad[0] + pad[d - 1];            /* keep the pad alive */
    } else {
        g_sp_call = read_sp();
        snprintf(b, bn, "%ld", (long)i);
        hold_sleep();
    }
}

static unsigned long v_iters;    /* file scope: must survive siglongjmp */

static void *victim_main(void *arg)
{
    char b[24];
    unsigned long sp;
    (void)arg;
    g_victim_up = 1;
    for (;;) {
        if (g_vpause) {
            struct timespec t = {0, 200000};
            g_vpaused = 1;
            while (g_vpause) nanosleep(&t, 0);
            g_vpaused = 0;
        }
        if (sigsetjmp(g_jb, 1) == 0) {
            g_ready = 1;
            hot_call(g_depth, v_iters, b, sizeof(b));
            v_iters++;
            sp = read_sp();
            if (sp && sp < g_sp_low) g_sp_low = sp;
            g_iters = v_iters;
        } else {
            g_ready = 1;
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
    char b[2048];
    const unsigned long lo = va - 256, hi = va + 32 + 256;
    const struct region *r = 0;
    int n, i;
    unsigned long a;

    if (va >= (unsigned long)g_rs.base && hi <= (unsigned long)g_rs.base + g_rs.size) r = &g_rs;
    else if (g_rd.base && va >= (unsigned long)g_rd.base &&
             hi <= (unsigned long)g_rd.base + g_rd.size) r = &g_rd;
    if (!r) return;

    n = s_cat(b, 0, (int)sizeof(b), "EV ");
    n += f_dec(b + n, now); b[n] = 0;
    n = s_cat(b, n, (int)sizeof(b), " CTX region=");
    n = s_cat(b, n, (int)sizeof(b), r == &g_rd ? "decoy" : "stack");
    n = f_cat_hex(b, n, (int)sizeof(b), " va=", va);
    n = f_cat_hex(b, n, (int)sizeof(b), " topva=", (unsigned long)g_rs_top - va);
    n = f_cat_hex(b, n, (int)sizeof(b), " spva=",
                  (g_sp_call > va) ? (g_sp_call - va) : 0);
    n = f_cat_dec(b, n, (int)sizeof(b), " ep=", (unsigned long)g_epoch);
    n = f_cat_hex(b, n, (int)sizeof(b), " D=", g_depth);
    n = s_cat(b, n, (int)sizeof(b), " win=");
    n += f_hex(b + n, lo); b[n++] = '-';
    n += f_hex(b + n, hi); b[n] = 0;
    n = s_cat(b, n, (int)sizeof(b), " hex=");
    for (a = lo; a < hi && n < (int)sizeof(b) - 3; a++) {
        unsigned char c = *(const volatile unsigned char *)a;
        b[n++] = "0123456789abcdef"[c >> 4];
        b[n++] = "0123456789abcdef"[c & 0xf];
    }
    b[n] = 0;
    emit(b, n);
    (void)i;
}

static void slot_emit(struct slot *s, const char *kind, unsigned long now)
{
    unsigned long pa = 0;
    if (s->region == 1) g_last_hit_va = s->va;
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
    if (cfg_wb && !s->sentineled) {
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
    unsigned long next_mig = (unsigned long)cfg_migsec * 1000000UL;
    (void)arg;
    while (!g_stop) {
        unsigned long t = now_us();
        scan_pass();
        age_slots(now_us());
        epoch_tick(t);
        stat_tick(t);
        if (cfg_dur && t >= (unsigned long)cfg_dur * 1000000UL) { g_stop = 1; }
        if (cfg_probe && t >= next_probe) { probe_decoy(t); next_probe = t + (unsigned long)cfg_probe * 1000000UL; }
        if (cfg_migsec && t >= next_mig) {
            unsigned long mva = cfg_migva ? cfg_migva : g_last_hit_va;
            if (mva) {
                unsigned long page = mva & ~0xfffUL;
                unsigned long pa0 = 0, pa1 = 0;
                /* NO pause: zap while live. Victim may take a recoverable SEGV
                 * inside hot_call (sigsetjmp scope) and re-materialize on a
                 * fresh anon page. That is exactly the discrimination we want. */
                patrace_pa(mva, &pa0);
                if (madvise((void *)page, 4096, MADV_DONTNEED) != 0)
                    logline("MIG_FAIL va=0x%lx errno=%d", mva, errno);
                else {
                    patrace_pa(mva, &pa1);
                    logline("MIG va=0x%lx page=0x%lx pa_before=%lx pa_after=%lx",
                            mva, page, pa0, pa1);
                }
            }
            next_mig = t + (unsigned long)cfg_migsec * 1000000UL;
        }
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
        "  --log-rule r       r1|r2|r3 (default r1)\n"
        "  --selftest 0|1     matcher self-test (default 1)\n");
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
        else if (!strcmp(a, "--stride")   && v) { cfg_stride = atoi(v); i++; }
        else if (!strcmp(a, "--duration") && v) { cfg_dur    = atoi(v); i++; }
        else if (!strcmp(a, "--log")      && v) { cfg_log    = v; i++; }
        else if (!strcmp(a, "--patrace")  && v) { cfg_patrace= v; i++; }
        else if (!strcmp(a, "--migrate-sec") && v) { cfg_migsec = atol(v); i++; }
        else if (!strcmp(a, "--migrate-va") && v) { cfg_migva = strtoul(v, 0, 0); i++; }
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
        else { fprintf(stderr, "unknown arg %s\n", a); usage(); return 2; }
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

    if (cfg_hmode) busy_calibrate();   /* D14: after g_t0_us/logfd, before any thread */

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
            "logrule=%d patrace=%s rules=R2(loose)|R1(w1==0&&w3==0&&len[0x40,0x20000]"
            "&&ip-unicast)|R1L(+private)|R3(w2==0x0109a8c000000641)",
            VERSION, g_pid, cfg_main ? "main" : "pthread",

            (unsigned long)g_rs.base, (unsigned long)g_rs.size, (unsigned long)g_rs_top,
            (unsigned long)g_rd.base, (unsigned long)cfg_decoy,
            cfg_period, cfg_hold, cfg_hmode, cfg_stride, cfg_wb, cfg_probe, cfg_churn, cfg_epoch,
            cfg_ndepth, cfg_cycle, cfg_logrule, cfg_patrace ? cfg_patrace : "none");

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
    logline("EXIT reason=duration passes=%lu appear=%lu rewrite=%lu rewrite_none=%lu "
            "selfcrash=%lu probe_ok=%lu probe_bad=%lu overflow=%lu selftest_ok=%lu "
            "selftest_bad=%lu iters=%lu scan_us_avg=%lu scan_us_max=%lu",
            st_pass, st_appear, st_rewrite, st_rewrite_none, g_selfcrash,
            st_probe_ok, st_probe_bad, st_overflow, st_selft_ok, st_selft_bad,
            g_iters, st_pass ? st_scan_us_sum / st_pass : 0, st_scan_us_max);
    if (g_logfd >= 0) close(g_logfd);
    return 0;
}
