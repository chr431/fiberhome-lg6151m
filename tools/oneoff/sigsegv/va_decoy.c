/* va_decoy.c -- U-D1/E1 inert decoy at the victim's numeric VA.
 *
 * Maps [base, base+size) at EXACTLY the victim's stack-window VA in a DIFFERENT
 * process (ASLR gives us an independent layout), pre-poisons it 0x5a, then scans
 * every 16 bytes for the same R1/R2 shape the scanner uses.  It never calls a
 * variadic function, never runs the victim loop and never writes into the region:
 * any DECOY_HIT is therefore an external write to a numeric VA, independent of
 * the victim process.
 *
 * Exit codes: 0 = ran; 4 = MAP_FIXED_NOREPLACE conflict (caller re-execs).
 *
 * Build: zig cc -target aarch64-linux-musl -O2 -static -o va_decoy va_decoy.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

#define PAGE     4096UL
#define REC      32
#define MAXSLOT  64
#define POISON   0x5a5a5a5a5a5a5a5aULL

static int  g_logfd = -1;
static volatile sig_atomic_t g_stop;
static unsigned long g_t0_mono;

static unsigned long mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long)(ts.tv_sec * 1000000UL + ts.tv_nsec / 1000UL) - g_t0_mono;
}

static void logline(const char *fmt, ...)
{
    char b[512];
    va_list ap;
    int n;
    n = snprintf(b, sizeof b, "EV %lu ", mono_us());
    if (n < 0) return;
    va_start(ap, fmt);
    n += vsnprintf(b + n, sizeof b - (size_t)n, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    b[n++] = '\n';
    if (g_logfd >= 0) (void)!write(g_logfd, b, (size_t)n);
}

/* same classes as scanary: 1 private, 2 public unicast, 3 invalid */
static int ip_class(uint32_t be)
{
    unsigned a = be & 0xffu, b = (be >> 8) & 0xffu;
    if (a == 0 || a == 255) return 3;
    if (a == 127 || a == 10) return 1;
    if (a == 172 && b >= 16 && b <= 31) return 1;
    if (a == 192 && b == 168) return 1;
    if (a == 169 && b == 254) return 1;
    if (a >= 224) return 3;
    return 2;
}

static int classify(const uint64_t *w, uint32_t *lenp, uint32_t *ipp)
{
    uint32_t len, ip;
    if (w[1] != 0 || w[3] != 0 || w[2] == 0) return 0;
    len = (uint32_t)(w[2] & 0xffffffffu);
    ip  = (uint32_t)(w[2] >> 32);
    if (len < 0x40 || len > 0x20000) return 0;
    if (ip_class(ip) == 3) return 0;
    *lenp = len; *ipp = ip;
    return 1;
}

struct slot { unsigned long va; uint64_t w[4]; unsigned long t0, tlast; };
static struct slot g_slot[MAXSLOT];

static void slot_touch(unsigned long va, const uint64_t *w)
{
    int i, free_i = -1;
    unsigned long now = mono_us();
    for (i = 0; i < MAXSLOT; i++) {
        if (!g_slot[i].va) { if (free_i < 0) free_i = i; continue; }
        {
            long d = (long)g_slot[i].va - (long)va;
            if (d >= -16 && d <= 16) {
                if (memcmp(g_slot[i].w, w, REC) != 0) {
                    memcpy(g_slot[i].w, w, REC);
                    g_slot[i].tlast = now;
                    logline("DECOY_CHANGE va=0x%lx poff=0x%lx w=%lx,%lx,%lx,%lx",
                            va, va & (PAGE - 1),
                            (unsigned long)w[0], (unsigned long)w[1],
                            (unsigned long)w[2], (unsigned long)w[3]);
                } else {
                    g_slot[i].tlast = now;
                }
                return;
            }
        }
    }
    if (free_i < 0) {
        /* evict oldest */
        int best = 0;
        for (i = 1; i < MAXSLOT; i++) if (g_slot[i].tlast < g_slot[best].tlast) best = i;
        free_i = best;
        logline("DECOY_GONE va=0x%lx residency_ms=%lu", g_slot[free_i].va,
                (g_slot[free_i].tlast - g_slot[free_i].t0) / 1000);
    }
    g_slot[free_i].va = va;
    memcpy(g_slot[free_i].w, w, REC);
    g_slot[free_i].t0 = now; g_slot[free_i].tlast = now;
    {
        uint32_t len = 0, ip = 0; (void)classify(w, &len, &ip);
        logline("DECOY_HIT va=0x%lx poff=0x%lx w=%lx,%lx,%lx,%lx len=%lu ip=%u.%u.%u.%u",
                va, va & (PAGE - 1),
                (unsigned long)w[0], (unsigned long)w[1],
                (unsigned long)w[2], (unsigned long)w[3],
                (unsigned long)len,
                (unsigned)(ip & 0xff), (unsigned)((ip >> 8) & 0xff),
                (unsigned)((ip >> 16) & 0xff), (unsigned)((ip >> 24) & 0xff));
    }
}

static void age_slots(void)
{
    int i;
    unsigned long now = mono_us();
    for (i = 0; i < MAXSLOT; i++) {
        if (!g_slot[i].va) continue;
        if (now - g_slot[i].tlast > 200000UL) {
            logline("DECOY_GONE va=0x%lx residency_ms=%lu", g_slot[i].va,
                    (g_slot[i].tlast - g_slot[i].t0) / 1000);
            g_slot[i].va = 0;
        }
    }
}

static void on_term(int sig) { (void)sig; g_stop = 1; }

int main(int argc, char **argv)
{
    unsigned long base, size;
    int dur = 600, passes = 0, hits = 0;
    unsigned char *p;
    struct timeval tv;
    struct sigaction sa;
    const char *logpath = "/data/repro/ud1_e1_decoy.log";

    if (argc < 3) {
        fprintf(stderr, "usage: %s <base_hex> <size> [seconds] [log]\n", argv[0]);
        return 2;
    }
    base = strtoul(argv[1], 0, 16);
    size = strtoul(argv[2], 0, 0);
    if (argc > 3) dur = atoi(argv[3]);
    if (argc > 4) logpath = argv[4];
    if (size < PAGE) size = PAGE;
    {   /* the victim's window base is top-2M and top is not page aligned */
        unsigned long off = base & (PAGE - 1);
        base -= off;
        size += off;
    }

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, 0);
    sigaction(SIGINT, &sa, 0);

    g_logfd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_logfd < 0) { fprintf(stderr, "open %s: %d\n", logpath, errno); return 2; }
    { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
      g_t0_mono = (unsigned long)(ts.tv_sec * 1000000UL + ts.tv_nsec / 1000UL); }
    gettimeofday(&tv, 0);
    logline("T0 epoch_us=%lld mono0_us=%lu pid=%d", 
            (long long)tv.tv_sec * 1000000LL + (long long)tv.tv_usec, g_t0_mono, (int)getpid());

    p = (unsigned char *)mmap((void *)base, size, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (p == MAP_FAILED) {
        int e = errno;
        logline("DECOY_MAP_FAIL base=0x%lx size=0x%lx errno=%d", base, size, e);
        return 4;
    }
    {
        uint64_t *q = (uint64_t *)p; size_t k;
        for (k = 0; k < size / 8; k++) q[k] = POISON;
    }
    logline("DECOY_START pid=%d base=0x%lx size=0x%lx dur=%d stride=16 poison=0x5a",
            (int)getpid(), (unsigned long)(uintptr_t)p, size, dur);

    while (!g_stop) {
        unsigned long off;
        unsigned long t0 = mono_us();
        for (off = 0; off + REC <= size; off += 16) {
            const uint64_t *w = (const uint64_t *)(p + off);
            uint32_t len = 0, ip = 0;
            if (!classify(w, &len, &ip)) continue;
            hits++;
            slot_touch((unsigned long)(uintptr_t)(p + off), w);
        }
        passes++;
        age_slots();
        if ((passes % 12000) == 0)
            logline("DECOY_TICK passes=%d hits=%d", passes, hits);
        if (g_stop) break;
        if (mono_us() - t0 < 5000UL) {
            struct timespec ts;
            unsigned long sl = 5000UL - (mono_us() - t0);
            ts.tv_sec = 0; ts.tv_nsec = (long)sl * 1000L;
            nanosleep(&ts, 0);
        }
        if (dur > 0 && mono_us() >= (unsigned long)dur * 1000000UL) break;
    }
    logline("DECOY_EXIT passes=%d hits=%d", passes, hits);
    if (g_logfd >= 0) close(g_logfd);
    return 0;
}
