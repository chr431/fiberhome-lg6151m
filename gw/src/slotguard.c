/*
 * slotguard.c v1.0 -- proactive sanitizer for known hot family-record slots.
 *
 * Role (docs/SIGSEGV/SLOTGUARD_DESIGN.md): nerepair repairs the crash AFTER the
 * corrupt 32-byte record has already been consumed as a va_list.  slotguard
 * removes the corrupt value BEFORE consumption: every few seconds it reads a
 * whitelisted slot on a long-lived daemon's stack, and if the content matches the
 * family record shape it rewrites that slot with a harmless value.
 *
 * Why a slot at all: sampler2 evidence (2026-11-01) shows long-lived daemons carry
 * a position-stable slot that is rewritten from outside:
 *   dnsmasq   start_stack-0x1b40  (3197 samples; content constant = stale record)
 *   nerepair  start_stack-0x3b0   (3065 samples; many distinct q0 = hot slot)
 *   nerepair  start_stack-0x12d0  (3197 samples)
 * The writer is still unnamed (FIX.md R-1); this is a compensation control, not a
 * root fix, and it does NOT stop the writes.
 *
 * The sanitize value is NOT zero.  A zero pointer turns the next pop into a NULL
 * dereference, which nerepair deliberately does not repair; the record's word0 is
 * always the value consumed as a pointer (nerepair's shape_ok requires
 * si_addr == w0), so word0 is rewritten to the slot's own address -- exactly
 * nerepair's "point it at the stack" repair, applied ahead of time.  That page is
 * mapped and its first word is the address itself, so repeated dereferences
 * succeed and a %s read stops at a NUL byte inside the address.  Words 1..3 are
 * zeroed (a zero length is a no-op for bounded copies; w1/w3 are already zero in
 * a valid record).
 *
 * DANGER SURFACE (design doc §4).  Every write needs ALL of:
 *   1. the slot is in the config with mode=sanitize (whitelist, exact comm match);
 *   2. /data/gw/slotguard.arm exists (second key, independent of the config);
 *   3. the 32 B content matches the strict family record shape (both forms);
 *   4. the same slot matched on >= 2 consecutive sweeps;
 *   5. the target task state is 'S' (sleeping);
 *   6. the current sp is known (/proc/<pid>/syscall) and the slot lies strictly
 *      BELOW it with a 128 B margin -> cannot be part of any live frame;
 *   7. the slot is inside the [stack] VMA, 8-aligned, not in the guard page;
 *   8. content, state and sp are re-read immediately before the write and must be
 *      unchanged;
 *   9. the per-slot hourly write budget is not exhausted and the storm breaker is
 *      not latched;
 *  10. no /proc/<pid>/mem permission failure has ever been seen (otherwise the
 *      whole process degrades to observe-only for its lifetime);
 *  11. the write is read back and must equal the intended 32 bytes; a mismatch
 *      latches that slot off for the rest of the session.
 * Anything not satisfied is logged with its reason and nothing is written.
 *
 * Self-learning: each sweep walks a bounded window below start_stack for the
 * configured comms and logs CANDIDATE lines for offsets that held a record on
 * >= 3 sweeps.  Candidates are never written -- promotion is a config edit.
 *
 * Telemetry:
 *   /data/gw/logs/slotguard.log     TSV events (1 MB rotate, 1 generation)
 *   /tmp/slotguard.hb               uptime seconds (watchdog svc_supervise)
 *   /tmp/slotguard.stats            one-line counters (ops read-out)
 *   /tmp/slotguard.alert            present only while the sanitize rate is high
 *                                   (watchdog 2 s fast path consumes it)
 *
 * Modes: --once (one sweep, stdout, zero side effects), --observe (never write),
 * --period N (default 3 s), --selftest (built-in assertions).
 *
 * Build: sh tools/build_slotguard.sh   (zig cc aarch64-linux-musl, static)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Host builds (the --selftest lane) are Windows/LLP64 and do not provide the
 * POSIX I/O used on the device.  These shims exist only there: the shipped
 * binary is musl aarch64 and takes the real code paths. */
#if defined(_WIN32) || !defined(__linux__)
static ssize_t sg_pread(int fd, void *buf, size_t len, long long off)
{
    if (lseek(fd, (long)off, SEEK_SET) < 0) return -1;
    return read(fd, buf, len);
}
static ssize_t sg_pwrite(int fd, const void *buf, size_t len, long long off)
{
    if (lseek(fd, (long)off, SEEK_SET) < 0) return -1;
    return write(fd, buf, len);
}
#define pread  sg_pread
#define pwrite sg_pwrite
#endif
static void sg_localtime(time_t t, struct tm *tm)
{
#if defined(_WIN32)
    struct tm *p = localtime(&t);
    if (p) *tm = *p;
#else
    localtime_r(&t, tm);
#endif
}

#define SG_VER "1.0"
#define LOGPATH "/data/gw/logs/slotguard.log"
#define HBPATH  "/tmp/slotguard.hb"
#define STATPATH "/tmp/slotguard.stats"
#define ALERTPATH "/tmp/slotguard.alert"
#define CONFPATH "/data/gw/slotguard.conf"
#define ARMPATH  "/data/gw/slotguard.arm"

#define REC_LEN_MIN 0x400UL
#define REC_LEN_MAX 0x20000UL
#define REC_A_MAX   (1UL << 24)
#define SG_PAGE     4096UL
#define SG_SP_MARGIN 128UL          /* bytes between the slot end and the live sp */
#define SG_MAX_SLOT 32
#define SG_MAX_SL  256
#define SG_MAX_CAND 256
#define SG_SCAN_PIDS 8              /* self-learning scans per sweep */

enum { SG_MODE_OBSERVE = 0, SG_MODE_SANITIZE = 1 };
enum {
    SG_OK = 0, SG_SKIP_MODE, SG_SKIP_UNARMED, SG_SKIP_NOREC, SG_SKIP_CONSEC,
    SG_SKIP_STATE, SG_SKIP_SP, SG_SKIP_LIVE, SG_SKIP_RANGE, SG_SKIP_ALIGN,
    SG_SKIP_BUDGET, SG_SKIP_COOLDOWN, SG_SKIP_PERM, SG_SKIP_N
};
static const char *sg_reason(int r)
{
    static const char *n[SG_SKIP_N] = {
        "ok", "mode=observe", "not-armed", "no-record", "consec<2", "state",
        "sp-unknown", "above-sp", "range", "align", "budget", "cooldown", "perm"
    };
    return (r >= 0 && r < SG_SKIP_N) ? n[r] : "?";
}
static int sg_selftest(void);

/* ---------------------------------------------------------------- records -- */
/* Strict family content test.  There is no fault address here, so the hard gates
 * are the record geometry plus an IPv4 plausibility check on the composite word
 * (strictly tighter than the validated 0/458752 strict shape, C-163).
 * Returns 0 = A0B2 (q0 small), 1 = B0A2 (q0 composite), -1 = no record. */
static int sg_ip_ok(unsigned long long hi)
{
    unsigned a = (unsigned)((hi >> 24) & 0xFF), b = (unsigned)((hi >> 16) & 0xFF);
    unsigned c = (unsigned)((hi >> 8) & 0xFF), d = (unsigned)(hi & 0xFF);

    return a >= 1 && a <= 254 && b >= 1 && b <= 254 && c >= 1 && c <= 254 && d >= 1 && d <= 254;
}
static int sg_classify(const unsigned long long w[4])
{
    unsigned long long lo0, lo2;

    if (w[1] != 0 || w[3] != 0)
        return -1;
    lo0 = w[0] & 0xFFFFFFFFUL;
    lo2 = w[2] & 0xFFFFFFFFUL;
    if (w[0] > 0 && w[0] < (unsigned long long)REC_A_MAX && lo2 >= REC_LEN_MIN &&
        lo2 <= REC_LEN_MAX && (w[2] >> 32) != 0 && sg_ip_ok(w[2] >> 32))
        return 0;                                   /* A0B2 */
    if (w[2] > 0 && w[2] < (unsigned long long)REC_A_MAX && lo0 >= REC_LEN_MIN &&
        lo0 <= REC_LEN_MAX && (w[0] >> 32) != 0 && sg_ip_ok(w[0] >> 32))
        return 1;                                   /* B0A2 */
    return -1;
}

/* ---------------------------------------------------------------- decision -- */
/* Pure decision function: no /proc access, no logging, no side effects.  The
 * built-in selftest drives it directly; this is the one function that must not
 * drift between the design doc and the binary. */
struct sg_facts {
    int mode;                   /* SG_MODE_* */
    int armed;
    int form;                   /* sg_classify() result */
    int consec;
    char state;                 /* /proc/<pid>/stat state char */
    int sp_known;
    unsigned long va, sp, stack_lo, stack_hi;
    unsigned long writes_1h, max_1h;
    int cooldown;
    int perm_denied;
};
static int sg_should_write(const struct sg_facts *f, const char **why)
{
    int r = SG_OK;

    if (f->mode != SG_MODE_SANITIZE)                 r = SG_SKIP_MODE;
    else if (!f->armed)                              r = SG_SKIP_UNARMED;
    else if (f->form < 0)                            r = SG_SKIP_NOREC;
    else if (f->consec < 2)                          r = SG_SKIP_CONSEC;
    else if (f->perm_denied)                         r = SG_SKIP_PERM;
    else if (f->cooldown)                            r = SG_SKIP_COOLDOWN;
    else if (f->state != 'S')                        r = SG_SKIP_STATE;
    else if (!f->sp_known)                           r = SG_SKIP_SP;
    else if (f->va + 32 + SG_SP_MARGIN > f->sp)      r = SG_SKIP_LIVE;
    else if (f->va < f->stack_lo + SG_PAGE)          r = SG_SKIP_RANGE;
    else if (f->va + 32 > f->stack_hi)               r = SG_SKIP_RANGE;
    else if (f->va & 7UL)                            r = SG_SKIP_ALIGN;
    else if (f->writes_1h >= f->max_1h)              r = SG_SKIP_BUDGET;
    if (why) *why = sg_reason(r);
    return r == SG_OK;
}

/* ------------------------------------------------------------------ config -- */
struct sg_slot {
    char comm[32];
    unsigned long off;          /* bytes below start_stack */
    int mode;
    unsigned long max_1h;
    unsigned long scan_win;     /* self-learning window (0 = off) */
};
static struct sg_slot g_slot[SG_MAX_SLOT];
static int g_nslot;

static int hexval(const char *s, unsigned long *out)
{
    char *end;
    unsigned long v;

    if (!s || !*s) return -1;
    v = strtoul(s, &end, 0);
    if (end == s || *end) return -1;
    *out = v;
    return 0;
}
static void slot_add(const char *comm, unsigned long off, int mode,
                     unsigned long max1h, unsigned long scanwin)
{
    int i;

    if (g_nslot >= SG_MAX_SLOT || !comm || !*comm) return;
    for (i = 0; i < g_nslot; i++)
        if (!strcmp(g_slot[i].comm, comm) && g_slot[i].off == off) return;
    snprintf(g_slot[g_nslot].comm, sizeof g_slot[g_nslot].comm, "%s", comm);
    g_slot[g_nslot].off = off;
    g_slot[g_nslot].mode = mode;
    g_slot[g_nslot].max_1h = max1h;
    g_slot[g_nslot].scan_win = scanwin;
    g_nslot++;
}
static void slot_defaults(void)
{
    slot_add("dnsmasq", 0x1b40UL, SG_MODE_OBSERVE, 120, 0x8000UL);
    slot_add("nerepair", 0x3b0UL, SG_MODE_OBSERVE, 120, 0x8000UL);
    slot_add("nerepair", 0x12d0UL, SG_MODE_OBSERVE, 120, 0);
}
/* Returns 0 when the config file was read, 1 when the built-in defaults were used. */
static int load_conf(void)
{
    FILE *f = fopen(CONFPATH, "r");
    char line[256];

    if (!f) { slot_defaults(); return 1; }
    while (fgets(line, sizeof line, f)) {
        char *p = line, *fld[5];
        int nf = 0;
        size_t L;

        while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '#' || *p == '\n') continue;
        L = strlen(line);
        while (L && (line[L - 1] == '\n' || line[L - 1] == '\r' || line[L - 1] == ' '))
            line[--L] = 0;
        fld[nf++] = p;
        while (*p && nf < 5) {
            if (*p == '|') { *p = 0; fld[nf++] = p + 1; }
            p++;
        }
        while (nf < 5) fld[nf++] = (char *)"";
        {
            unsigned long off = 0, mx = 120, win = 0;
            int mode = SG_MODE_OBSERVE;

            if (hexval(fld[1], &off) < 0) continue;
            if (fld[2][0] == 's' || fld[2][0] == 'S') mode = SG_MODE_SANITIZE;
            if (*fld[3] && hexval(fld[3], &mx) < 0) continue;
            if (*fld[4] && hexval(fld[4], &win) < 0) continue;
            if (mx > 100000) mx = 100000;
            if (win > 0x20000) win = 0x20000;
            if (off < 64 || off > 0x7F000) continue;      /* sane slot offsets */
            slot_add(fld[0], off, mode, mx, win);
        }
    }
    fclose(f);
    if (!g_nslot) { slot_defaults(); return 1; }
    return 0;
}

/* -------------------------------------------------------------- /proc facts -- */
static pid_t g_self;
static pid_t g_anc[16];
static int g_nanc;

static void anc_init(void)
{
    pid_t p = g_self;
    int i;
    char path[64], buf[512];

    for (i = 0; i < 16; i++) {
        int fd, n;
        char *rp, *q;
        unsigned long ppid = 0;

        snprintf(path, sizeof path, "/proc/%d/stat", (int)p);
        fd = open(path, O_RDONLY);
        if (fd < 0) break;
        n = read(fd, buf, sizeof buf - 1); close(fd);
        if (n <= 0) break;
        buf[n] = 0;
        rp = strrchr(buf, ')');
        if (!rp) break;
        q = rp + 2;
        while (*q == ' ') q++;                 /* state */
        while (*q && *q != ' ') q++;
        while (*q == ' ') q++;
        ppid = strtoul(q, NULL, 10);           /* field 4 */
        if (ppid <= 1) break;
        g_anc[g_nanc++] = (pid_t)ppid;
        p = (pid_t)ppid;
    }
}
static int is_anc(pid_t p)
{
    int i;

    for (i = 0; i < g_nanc; i++) if (g_anc[i] == p) return 1;
    return 0;
}
/* /proc/<pid>/stat: comm (exact token between the first '(' and the LAST ')'),
 * state, ppid, start_stack (field 28).  Returns 0 on success. */
static int proc_stat(pid_t pid, char *comm, size_t cn, char *state,
                     pid_t *ppid, unsigned long *start_stack)
{
    char path[64], buf[1024];
    char *lp, *rp, *q, *tok;
    int fd, n, idx = 0;

    snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    n = read(fd, buf, sizeof buf - 1); close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    lp = strchr(buf, '(');
    rp = strrchr(buf, ')');
    if (!lp || !rp || rp <= lp) return -1;
    if ((size_t)(rp - lp - 1) >= cn) return -1;
    memcpy(comm, lp + 1, (size_t)(rp - lp - 1));
    comm[rp - lp - 1] = 0;
    q = rp + 2;
    if (state) *state = *q;
    if (ppid) *ppid = 0;
    if (start_stack) *start_stack = 0;
    for (tok = strtok(q, " "); tok; tok = strtok(NULL, " ")) {
        if (idx == 1 && ppid) *ppid = (pid_t)strtol(tok, NULL, 10);
        if (idx == 25) {
            if (start_stack) *start_stack = strtoul(tok, NULL, 10);
            break;
        }
        idx++;
    }
    return 0;
}
/* Current sp of the main thread; failure means "unknown" (no write allowed). */
static int proc_sp(pid_t pid, unsigned long *sp)
{
    char path[64], buf[256];
    char *tok[10];
    int fd, n, k = 0;
    char *t;

    *sp = 0;
    snprintf(path, sizeof path, "/proc/%d/syscall", (int)pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    n = read(fd, buf, sizeof buf - 1); close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    if (buf[0] < '0' || buf[0] > '9') return -1;      /* "running" / "-1 ..." */
    for (t = strtok(buf, " \n"); t && k < 10; t = strtok(NULL, " \n")) tok[k++] = t;
    if (k < 8) return -1;                             /* nr, 6 args, sp, pc */
    *sp = strtoul(tok[7], NULL, 16);
    return *sp ? 0 : -1;
}
static int proc_stack_bounds(pid_t pid, unsigned long *lo, unsigned long *hi)
{
    char path[64], line[512];
    FILE *f;
    int ok = -1;

    snprintf(path, sizeof path, "/proc/%d/maps", (int)pid);
    f = fopen(path, "r");
    if (!f) return -1;
    while (fgets(line, sizeof line, f)) {
        unsigned long a, b;
        if (strstr(line, "[stack]") && sscanf(line, "%lx-%lx", &a, &b) == 2) {
            *lo = a; *hi = b; ok = 0; break;
        }
    }
    fclose(f);
    return ok;
}
static int read_mem(pid_t pid, unsigned long va, void *buf, size_t len)
{
    char path[64];
    int fd;
    ssize_t r;

    snprintf(path, sizeof path, "/proc/%d/mem", (int)pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    r = pread(fd, buf, len, (off_t)va);
    close(fd);
    return r == (ssize_t)len ? 0 : -1;
}
/* returns 0 on success; *perm=1 for EACCES/EPERM */
static int write_mem(pid_t pid, unsigned long va, const void *buf, size_t len, int *perm)
{
    char path[64];
    int fd;
    ssize_t r;

    *perm = 0;
    snprintf(path, sizeof path, "/proc/%d/mem", (int)pid);
    fd = open(path, O_RDWR);
    if (fd < 0) { if (errno == EACCES || errno == EPERM) *perm = 1; return -1; }
    r = pwrite(fd, buf, len, (off_t)va);
    if (r < 0 && (errno == EACCES || errno == EPERM)) *perm = 1;
    close(fd);
    return r == (ssize_t)len ? 0 : -1;
}

/* ------------------------------------------------------------------ logging -- */
static int g_logfd = -1;
static int g_quiet;                        /* --once: stdout only */
static unsigned long g_suppressed;
static unsigned long g_match, g_would, g_wrote, g_skip_live, g_skip_state,
                     g_skip_perm, g_skip_other, g_candidates;
static int g_perm_denied;
static int g_observe_only;
static int g_armed;
static unsigned long g_sweeps;
static volatile sig_atomic_t g_term;

static void on_term(int s) { (void)s; g_term = 1; }

static int rate_ok(void)
{
    static time_t w;
    static int c;
    time_t now = time(NULL);

    if (now != w) { w = now; c = 0; }
    if (c >= 40) { g_suppressed++; return 0; }
    c++;
    return 1;
}
static void rotate_log(void)
{
    struct stat st;

    if (g_logfd < 0) return;
    if (fstat(g_logfd, &st) == 0 && st.st_size > 1024 * 1024) {
        close(g_logfd);
        rename(LOGPATH, LOGPATH ".1");
        g_logfd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
}
static void logev(const char *ev, pid_t pid, const char *comm, const char *fmt, ...)
{
    char msg[512];
    time_t t;
    struct tm tm;
    int n, m;
    va_list ap;

    time(&t);
    sg_localtime(t, &tm);
    n = snprintf(msg, sizeof msg, "%ld\t%04d-%02d-%02dT%02d:%02d:%02d\t%d\t%s\t%s\t",
                 (long)t, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                 tm.tm_hour, tm.tm_min, tm.tm_sec, (int)pid, comm ? comm : "-", ev);
    if (n < 0) return;
    if (n > (int)sizeof msg - 2) n = (int)sizeof msg - 2;
    va_start(ap, fmt);
    m = vsnprintf(msg + n, sizeof msg - n, fmt, ap);
    va_end(ap);
    if (m < 0) m = 0;
    if (m > (int)sizeof msg - 1 - n) m = (int)sizeof msg - 1 - n;
    n += m;
    msg[n++] = '\n';
    if (g_quiet) { fwrite(msg, 1, (size_t)n, stdout); return; }
    if (g_logfd >= 0) { ssize_t r = write(g_logfd, msg, (size_t)n); (void)r; }
    rotate_log();
}
static void write_file(const char *path, const char *buf, size_t len)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

    if (fd >= 0) { if (write(fd, buf, len) != (ssize_t)len) {} close(fd); }
}
static void write_hb(void)
{
    char b[32];
    int fd, n;
    unsigned long up = 0;

    fd = open("/proc/uptime", O_RDONLY);
    if (fd >= 0) {
        n = read(fd, b, sizeof b - 1); close(fd);
        if (n > 0) { b[n] = 0; up = strtoul(b, NULL, 10); }
    }
    n = snprintf(b, sizeof b, "%lu", up);
    write_file(HBPATH, b, (size_t)n);
}

/* --------------------------------------------------------------- bookkeeping -- */
struct sg_sl {
    pid_t pid;
    unsigned long off;
    int consec;
    int form;
    time_t last;
    time_t win_start;
    unsigned long writes;
    time_t cooldown_until;
    int latched;                        /* post-write verify failed: never write again */
};
static struct sg_sl g_sl[SG_MAX_SL];

static struct sg_sl *sl_get(pid_t pid, unsigned long off, time_t now, int create)
{
    int i, free_slot = -1;

    for (i = 0; i < SG_MAX_SL; i++) {
        if (g_sl[i].pid == pid && g_sl[i].off == off) return &g_sl[i];
        if (free_slot < 0 && (g_sl[i].pid == 0 || g_sl[i].last < now - 3600))
            free_slot = i;
    }
    if (!create) return NULL;
    if (free_slot < 0) free_slot = (int)(((unsigned)pid ^ off) % SG_MAX_SL);
    memset(&g_sl[free_slot], 0, sizeof g_sl[free_slot]);
    g_sl[free_slot].pid = pid;
    g_sl[free_slot].off = off;
    g_sl[free_slot].win_start = now;
    return &g_sl[free_slot];
}

struct sg_cand {
    char comm[32];
    unsigned long off;
    int hits;
    int form;
    time_t last;
    int logged;
};
static struct sg_cand g_cand[SG_MAX_CAND];

static void cand_note(const char *comm, unsigned long off, int form, time_t now)
{
    int i, free_slot = -1;

    for (i = 0; i < SG_MAX_CAND; i++) {
        if (g_cand[i].comm[0] && !strcmp(g_cand[i].comm, comm) && g_cand[i].off == off) {
            if (now - g_cand[i].last > 300) g_cand[i].hits = 0;
            g_cand[i].hits++;
            g_cand[i].last = now;
            g_cand[i].form = form;
            if (!g_cand[i].logged && g_cand[i].hits >= 3) {
                g_cand[i].logged = 1;
                g_candidates++;
                if (rate_ok())
                    logev("CANDIDATE", 0, comm,
                          "off=0x%lx form=%s hits=%d (observe-only; promote by editing %s)",
                          off, form ? "B0A2" : "A0B2", g_cand[i].hits, CONFPATH);
            }
            return;
        }
        if (free_slot < 0 && !g_cand[i].comm[0]) free_slot = i;
    }
    if (free_slot < 0) return;
    snprintf(g_cand[free_slot].comm, sizeof g_cand[free_slot].comm, "%s", comm);
    g_cand[free_slot].off = off;
    g_cand[free_slot].form = form;
    g_cand[free_slot].hits = 1;
    g_cand[free_slot].last = now;
    g_cand[free_slot].logged = 0;
}

/* --------------------------------------------------------------- rate alert -- */
#define SG_RATE_N 256
static time_t g_rate_ts[SG_RATE_N];
static int g_rate_i;
static unsigned long g_rate_total;
static int g_alert_on;
static unsigned long g_alert_thresh = 30;      /* sanitizes / 60 s */

static void rate_note(time_t now)
{
    g_rate_ts[g_rate_i] = now;
    g_rate_i = (g_rate_i + 1) % SG_RATE_N;
    g_rate_total++;
}
static int rate_recent(time_t now)
{
    int i, n = 0;

    for (i = 0; i < SG_RATE_N; i++)
        if (g_rate_ts[i] && now - g_rate_ts[i] < 60) n++;
    return n;
}
static void alert_update(time_t now, const char *comm, unsigned long off)
{
    int n = rate_recent(now);

    if (n >= (int)g_alert_thresh && !g_alert_on) {
        char b[160];
        int L;

        g_alert_on = 1;
        L = snprintf(b, sizeof b, "ts=%ld rate=%d total=%lu slot=%s/0x%lx\n",
                     (long)now, n, g_rate_total, comm ? comm : "-", off);
        write_file(ALERTPATH, b, (size_t)L);
        if (rate_ok())
            logev("ALERT", 0, comm ? comm : "-", "rate=%d/min thresh=%lu total=%lu off=0x%lx",
                  n, g_alert_thresh, g_rate_total, off);
    } else if (n == 0 && g_alert_on) {
        g_alert_on = 0;
        unlink(ALERTPATH);
        if (rate_ok()) logev("ALERT_CLEAR", 0, "-", "rate=0 total=%lu", g_rate_total);
    }
}

static void write_stats(void)
{
    char b[256];
    int n;

    n = snprintf(b, sizeof b,
                 "sweeps=%lu match=%lu would=%lu wrote=%lu skip_live=%lu skip_state=%lu "
                 "skip_perm=%lu skip_other=%lu cand=%lu alert=%d total=%lu\n",
                 g_sweeps, g_match, g_would, g_wrote, g_skip_live, g_skip_state,
                 g_skip_perm, g_skip_other, g_candidates, g_alert_on, g_rate_total);
    write_file(STATPATH, b, (size_t)n);
}

static int comm_in_conf(const char *comm)
{
    int i;

    for (i = 0; i < g_nslot; i++) if (!strcmp(g_slot[i].comm, comm)) return 1;
    return 0;
}

/* --------------------------------------------------------------------- sweep -- */
static void sanitize_one(pid_t pid, const char *comm, const struct sg_slot *sl,
                         struct sg_sl *st, unsigned long start_stack,
                         unsigned long stack_lo, unsigned long stack_hi,
                         time_t now)
{
    unsigned long va = start_stack - sl->off;
    unsigned long long w[4], w2[4];
    unsigned long sp = 0, sp2 = 0, ss2 = 0;
    char state = '?';
    char c2[64];
    pid_t ppid = 0;
    struct sg_facts f;
    const char *why = "";
    int form;

    if (read_mem(pid, va, w, 32) < 0) { st->consec = 0; return; }
    form = sg_classify(w);
    if (form < 0) { st->consec = 0; return; }
    g_match++;
    st->consec++;
    st->form = form;
    st->last = now;
    if (st->win_start == 0 || now - st->win_start >= 3600) {
        st->win_start = now;
        st->writes = 0;
    }
    if (st->consec == 2 && rate_ok())
        logev("MATCH", pid, comm, "off=0x%lx va=0x%lx form=%s q0=0x%llx q2=0x%llx",
              sl->off, va, form ? "B0A2" : "A0B2", w[0], w[2]);
    cand_note(comm, sl->off, form, now);

    if (sl->mode != SG_MODE_SANITIZE || !g_armed || g_observe_only) {
        if (st->consec == 2) {
            g_would++;
            if (rate_ok())
                logev("WOULD_SANITIZE", pid, comm,
                      "off=0x%lx va=0x%lx form=%s q0=0x%llx q2=0x%llx reason=%s",
                      sl->off, va, form ? "B0A2" : "A0B2", w[0], w[2],
                      g_observe_only ? "observe-flag" : (g_armed ? "mode=observe" : "not-armed"));
        }
        return;
    }
    if (st->latched) { g_skip_other++; return; }

    if (proc_stat(pid, c2, sizeof c2, &state, &ppid, &ss2) < 0 || strcmp(c2, comm) != 0) {
        st->consec = 0; return;
    }
    if (ss2 != start_stack) { st->consec = 0; return; }   /* stack re-laid: re-learn */
    if (proc_sp(pid, &sp) < 0) sp = 0;

    f.mode = sl->mode; f.armed = g_armed; f.form = form; f.consec = st->consec;
    f.state = state; f.sp_known = sp != 0; f.va = va; f.sp = sp;
    f.stack_lo = stack_lo; f.stack_hi = stack_hi;
    f.writes_1h = st->writes; f.max_1h = sl->max_1h;
    f.cooldown = now < st->cooldown_until; f.perm_denied = g_perm_denied;
    if (!sg_should_write(&f, &why)) {
        if (!strcmp(why, "above-sp")) {
            g_skip_live++;
            if (rate_ok())
                logev("SKIP", pid, comm, "off=0x%lx va=0x%lx reason=above-sp sp=0x%lx state=%c",
                      sl->off, va, sp, state);
        } else if (!strcmp(why, "state") || !strcmp(why, "sp-unknown")) {
            g_skip_state++;
        } else if (!strcmp(why, "perm")) {
            g_skip_perm++;
        } else {
            g_skip_other++;
        }
        return;
    }

    /* Re-read everything immediately before touching memory.  Any change aborts. */
    if (proc_stat(pid, c2, sizeof c2, &state, &ppid, &ss2) < 0 || strcmp(c2, comm) != 0 ||
        ss2 != start_stack || state != 'S' || proc_sp(pid, &sp2) < 0 || sp2 != sp) {
        g_skip_state++;
        if (rate_ok())
            logev("SKIP", pid, comm, "off=0x%lx reason=state-changed state=%c sp=0x%lx->0x%lx",
                  sl->off, state, sp, sp2);
        return;
    }
    if (read_mem(pid, va, w2, 32) < 0 || sg_classify(w2) < 0) {
        g_skip_other++;
        if (rate_ok())
            logev("SKIP", pid, comm, "off=0x%lx reason=content-changed", sl->off);
        return;
    }
    {
        unsigned long expect[4], back[4];
        int perm = 0;

        expect[0] = va; expect[1] = 0; expect[2] = 0; expect[3] = 0;
        if (write_mem(pid, va, expect, 32, &perm) < 0) {
            if (perm) {
                g_perm_denied = 1;
                logev("PERM", pid, comm, "off=0x%lx errno=%d -> observe-only for this session",
                      sl->off, errno);
            } else {
                st->latched = 1;
                logev("WRITE_FAIL", pid, comm, "off=0x%lx errno=%d -> slot latched off",
                      sl->off, errno);
            }
            return;
        }
        st->writes++;
        rate_note(now);
        if (read_mem(pid, va, back, 32) < 0 ||
            back[0] != expect[0] || back[1] != 0 || back[2] != 0 || back[3] != 0) {
            st->latched = 1;
            logev("WRITE_MISMATCH", pid, comm,
                  "off=0x%lx want=0x%lx,0,0,0 got=0x%lx,0x%lx,0x%lx,0x%lx -> slot latched off",
                  sl->off, expect[0], back[0], back[1], back[2], back[3]);
            return;
        }
    }
    g_wrote++;
    logev("SANITIZE", pid, comm,
          "off=0x%lx va=0x%lx form=%s pre=0x%llx,0x%llx,0x%llx,0x%llx post=0x%lx,0,0,0 sp=0x%lx state=%c writes_1h=%lu",
          sl->off, va, form ? "B0A2" : "A0B2", w[0], w[1], w[2], w[3], va, sp, state, st->writes);
    /* rate alert carries the slot that tripped it (the sweep-end call only clears) */
    alert_update(now, comm, sl->off);
    if (st->writes >= 5 && now - st->win_start < 60) {
        st->cooldown_until = now + 600;
        if (rate_ok())
            logev("STORM", pid, comm, "off=0x%lx writes=%lu in %lds -> 600s cooldown",
                  sl->off, st->writes, (long)(now - st->win_start));
    }
}

/* self-learning: bounded walk of [start_stack-win, start_stack) */
static void learn_scan(pid_t pid, const char *comm, unsigned long start_stack,
                       unsigned long win, time_t now)
{
    unsigned char buf[SG_PAGE];
    unsigned long p;

    if (win == 0 || win > 0x20000) return;
    for (p = start_stack - win; p < start_stack; p += SG_PAGE) {
        unsigned long off;

        if (read_mem(pid, p, buf, SG_PAGE) < 0) continue;
        for (off = 0; off + 32 <= SG_PAGE; off += 8) {
            unsigned long long w[4];
            unsigned long va = p + off;
            int form, i, skip = 0;

            memcpy(w, buf + off, 32);
            form = sg_classify(w);
            if (form < 0) continue;
            for (i = 0; i < g_nslot; i++)
                if (!strcmp(g_slot[i].comm, comm) && g_slot[i].off == start_stack - va) skip = 1;
            if (skip) continue;
            cand_note(comm, start_stack - va, form, now);
        }
    }
}

static int get_int_or(const char *s, int def)
{
    char *e;
    long v;

    if (!s) return def;
    v = strtol(s, &e, 10);
    return (e == s) ? def : (int)v;
}

int main(int argc, char **argv)
{
    int once = 0, period = 3, i, conf_default;
    time_t now;

    g_self = getpid();
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "--observe")) g_observe_only = 1;
        else if (!strcmp(argv[i], "--period") && i + 1 < argc) period = get_int_or(argv[++i], 3);
        else if (!strcmp(argv[i], "--selftest")) return sg_selftest();
        else if (!strcmp(argv[i], "--version")) { printf("slotguard v%s\n", SG_VER); return 0; }
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: slotguard [--once] [--observe] [--period S] [--selftest]\n");
            return 0;
        }
    }
    if (period < 1) period = 1;
    if (period > 60) period = 60;
    g_quiet = once;
    conf_default = load_conf();
    anc_init();
    /* signal() is enough: the handler only sets a flag and the loop polls it. */
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    if (!once) {
        g_logfd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (access(ARMPATH, F_OK) == 0) g_armed = 1;
        logev("START", 0, "-", "pid=%d ver=%s slots=%d conf=%s armed=%d observe_only=%d period=%ds",
              (int)g_self, SG_VER, g_nslot, conf_default ? "default" : CONFPATH,
              g_armed, g_observe_only, period);
        write_hb();
        write_stats();
    }
    do {
        DIR *d = opendir("/proc");
        struct dirent *de;
        int learn_budget = SG_SCAN_PIDS;

        now = time(NULL);
        if (d) {
            while ((de = readdir(d))) {
                pid_t pid;
                char comm[64], state;
                pid_t ppid;
                unsigned long start_stack, lo = 0, hi = 0, win = 0;
                int k;

                if (de->d_name[0] < '1' || de->d_name[0] > '9') continue;
                pid = (pid_t)atoi(de->d_name);
                if (pid == g_self || is_anc(pid)) continue;        /* 定律三 */
                if (proc_stat(pid, comm, sizeof comm, &state, &ppid, &start_stack) < 0)
                    continue;
                if (!start_stack || !comm_in_conf(comm)) continue;  /* exact token */
                if (proc_stack_bounds(pid, &lo, &hi) < 0) continue;
                if (start_stack < lo || start_stack > hi) continue;
                for (k = 0; k < g_nslot; k++) {
                    struct sg_sl *st;

                    if (strcmp(g_slot[k].comm, comm)) continue;
                    st = sl_get(pid, g_slot[k].off, now, 1);
                    sanitize_one(pid, comm, &g_slot[k], st, start_stack, lo, hi, now);
                    if (g_slot[k].scan_win > win) win = g_slot[k].scan_win;
                }
                if (win && learn_budget > 0) {
                    learn_scan(pid, comm, start_stack, win, now);
                    learn_budget--;
                }
            }
            closedir(d);
        }
        g_sweeps++;
        if (!once) {
            alert_update(now, NULL, 0);   /* clears the alert once the rate window is empty */
            if (g_sweeps % 5 == 0) write_hb();
            if (g_sweeps % 20 == 0) {
                write_stats();
                logev("STAT", 0, "-",
                      "sweeps=%lu match=%lu would=%lu wrote=%lu live=%lu state=%lu perm=%lu "
                      "other=%lu cand=%lu suppressed=%lu armed=%d",
                      g_sweeps, g_match, g_would, g_wrote, g_skip_live, g_skip_state,
                      g_skip_perm, g_skip_other, g_candidates, g_suppressed, g_armed);
            }
        }
        if (once) break;
        for (i = 0; i < period * 10 && !g_term; i++) usleep(100000);
    } while (!g_term);
    if (!once) {
        write_stats();
        logev("EXIT", 0, "-", "sweeps=%lu wrote=%lu suppressed=%lu", g_sweeps, g_wrote, g_suppressed);
    }
    return 0;
}

/* ------------------------------------------------------------------ selftest -- */
/* Built-in assertions for the two things that must never drift: the record
 * classifier and the write decision.  Run with --selftest; exit code 1 on any
 * failure.  Works on the device and on a host build. */
static int st_fail;
static void st_ck(int cond, const char *what)
{
    if (!cond) { printf("FAIL %s\n", what); st_fail++; }
}
static int sg_selftest(void)
{
    const unsigned long long pos[][4] = {
        {0x20090, 0, 0x04D08ADE0000062FUL, 0}, {0x20085, 0, 0x04D08ADE0000062FUL, 0},
        {0x23648, 0, 0x04D08ADE0000062FUL, 0}, {0x1c949, 0, 0x04D08ADE0000062FUL, 0},
        {0x21d50, 0, 0x04D08ADE0000062FUL, 0}, {0x21d43, 0, 0x04D08ADE0000062FUL, 0},
        {0x22aaf, 0, 0x04D08ADE0000062FUL, 0},
    };
    unsigned long long w[4];
    size_t i;
    int npos = 0;
    struct sg_facts f;
    const char *why;

    for (i = 0; i < sizeof pos / sizeof pos[0]; i++) {
        memcpy(w, pos[i], sizeof w);
        if (sg_classify(w) == 0) npos++;
    }
    st_ck(npos == 7, "7/7 natural-NE records accepted as A0B2");
    { unsigned long long b[4] = {0x0109a8c000000649ULL, 0, 0x1c949, 0};
      st_ck(sg_classify(b) == 1, "B0A2 record accepted"); }
    { unsigned long long b[4] = {0x20090, 1, 0x04D08ADE0000062FUL, 0};
      st_ck(sg_classify(b) < 0, "w1 != 0 rejected"); }
    { unsigned long long b[4] = {0x20090, 0, 0x04D08ADE0000062FUL, 7};
      st_ck(sg_classify(b) < 0, "w3 != 0 rejected"); }
    { unsigned long long b[4] = {0x20090, 0, 0x04D08ADE00000010UL, 0};
      st_ck(sg_classify(b) < 0, "length below band rejected"); }
    { unsigned long long b[4] = {0x20090, 0, 0x00010000F0000000UL, 0};
      st_ck(sg_classify(b) < 0, "implausible IP rejected"); }
    { unsigned long long b[4] = {0x1000000, 0, 0x04D08ADE0000062FUL, 0};
      st_ck(sg_classify(b) < 0, "A word above 24 bits rejected"); }
    { unsigned long long b[4] = {0, 0, 0, 0};
      st_ck(sg_classify(b) < 0, "all-zero rejected"); }
    { unsigned long long b[4] = {0x20090, 0, 0, 0};
      st_ck(sg_classify(b) < 0, "record without composite rejected"); }

    memset(&f, 0, sizeof f);
    f.mode = SG_MODE_SANITIZE; f.armed = 1; f.form = 0; f.consec = 2;
    f.state = 'S'; f.sp_known = 1;
    f.va = 0x2000; f.stack_lo = 0x1000; f.stack_hi = 0x9000;
    f.sp = f.va + 32 + SG_SP_MARGIN + 64;
    f.max_1h = 120;
    st_ck(sg_should_write(&f, &why) == 1, "baseline write allowed");
    f.mode = SG_MODE_OBSERVE;
    st_ck(!sg_should_write(&f, &why) && !strcmp(why, "mode=observe"), "observe blocked");
    f.mode = SG_MODE_SANITIZE; f.armed = 0;
    st_ck(!sg_should_write(&f, &why) && !strcmp(why, "not-armed"), "unarmed blocked");
    f.armed = 1; f.form = -1;
    st_ck(!sg_should_write(&f, &why), "no record blocked");
    f.form = 0; f.consec = 1;
    st_ck(!sg_should_write(&f, &why), "consec<2 blocked");
    f.consec = 2; f.state = 'R';
    st_ck(!sg_should_write(&f, &why) && !strcmp(why, "state"), "running state blocked");
    f.state = 'S'; f.sp_known = 0;
    st_ck(!sg_should_write(&f, &why), "unknown sp blocked");
    f.sp_known = 1; f.va = f.sp - 64;
    st_ck(!sg_should_write(&f, &why) && !strcmp(why, "above-sp"), "slot at/above sp blocked");
    f.va = 0x2000; f.sp = f.va + 32 + SG_SP_MARGIN + 64; f.stack_lo = f.va;
    st_ck(!sg_should_write(&f, &why), "guard page blocked");
    f.stack_lo = 0x1000; f.va = 0x2004; f.sp = f.va + 32 + SG_SP_MARGIN + 64;
    st_ck(!sg_should_write(&f, &why) && !strcmp(why, "align"), "unaligned blocked");
    f.va = 0x2000; f.sp = f.va + 32 + SG_SP_MARGIN + 64; f.writes_1h = 120;
    st_ck(!sg_should_write(&f, &why) && !strcmp(why, "budget"), "budget blocked");
    f.writes_1h = 0; f.cooldown = 1;
    st_ck(!sg_should_write(&f, &why), "cooldown blocked");
    f.cooldown = 0; f.perm_denied = 1;
    st_ck(!sg_should_write(&f, &why) && !strcmp(why, "perm"), "perm denial blocks");
    f.perm_denied = 0;
    st_ck(sg_should_write(&f, &why) == 1, "baseline re-allowed");

    printf("%s (%d failures)\n", st_fail ? "SELFTEST FAILED" : "SELFTEST PASSED", st_fail);
    return st_fail ? 1 : 0;
}
