/* vsurv4.c -- canary with an async-signal-safe SIGSEGV handler.
 *
 * Why v4:
 *   vsurv3's handler calls snprintf(), open("/proc/self/maps"), read(), and
 *   uses SA_NODEFER.  That makes the handler a second victim, produces
 *   post-handler stack dumps, and can recurse.  v4:
 *     - runs on a sigaltstack;
 *     - uses only open/write/close/time (async-signal-safe);
 *     - caches start_stack at startup (no /proc read in the handler);
 *     - formats the path manually (no snprintf);
 *     - blocks the signal during the handler (no SA_NODEFER);
 *     - has a g_in_handler guard;
 *     - writes a fixed binary header + N stack pages.
 *
 * Output format (little-endian):
 *   struct h4_hdr (96 bytes) + NPAGES * 4096 bytes
 *   h4_hdr.magic = "H5v1\0\0\0\0"
 *
 * Build:
 *   zig cc -target aarch64-linux-musl -static -O2 -o vsurv4 vsurv4.c
 *   (or aarch64-linux-musl-gcc -static -O2)
 *
 * The handler still uses siglongjmp(), which POSIX does not list as
 * async-signal-safe but is the established way to resume this canary.  If a
 * nested SIGSEGV is delivered, g_in_handler causes _exit(139) instead of
 * recursing.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <stdarg.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#define NPAGES 8
#define PAGE 4096
static const char H5_MAGIC[8] = {'H', '4', 'v', '1', 0, 0, 0, 0};

struct h4_hdr {
    char magic[8];
    uint32_t version;
    uint32_t pid;
    uint32_t hit;
    uint32_t sig;
    uint64_t addr;
    uint64_t fault_address;
    uint64_t pc;
    uint64_t sp;
    uint64_t x2;
    uint64_t x8;
    uint64_t x29;
    uint64_t x30;
    uint64_t pstate;
    uint64_t stack_top;
    uint32_t npages;
    uint32_t pad;
    uint64_t ts;
} __attribute__((packed));
_Static_assert(sizeof(struct h4_hdr) == 120, "h4_hdr size");

static sigjmp_buf g_jb;
static volatile sig_atomic_t g_in_handler;
static volatile sig_atomic_t g_ready;
static volatile unsigned int g_hits;
static unsigned long g_stack_top;
static int g_pid;

static char g_altstack[64 * 1024] __attribute__((aligned(16)));

static int fmt_u32(char *p, unsigned int v)
{
    char tmp[16];
    int n = 0, i;
    if (v == 0) {
        p[0] = '0';
        return 1;
    }
    while (v && n < (int)sizeof(tmp)) {
        tmp[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    for (i = 0; i < n; i++)
        p[i] = tmp[n - 1 - i];
    return n;
}

static int fmt_hex(char *p, unsigned long v)
{
    static const char h[] = "0123456789abcdef";
    char tmp[16];
    int n = 0, i;
    if (v == 0) { p[0] = '0'; return 1; }
    while (v && n < (int)sizeof(tmp)) {
        tmp[n++] = h[v & 0xf];
        v >>= 4;
    }
    for (i = 0; i < n; i++)
        p[i] = tmp[n - 1 - i];
    return n;
}

static int fmt_path(char *p, int cap, int pid, unsigned int hit)
{
    const char *pre = "/data/repro/h5_";
    int n = 0;
    while (*pre && n < cap - 1)
        p[n++] = *pre++;
    n += fmt_u32(p + n, (unsigned int)pid);
    if (n < cap - 1)
        p[n++] = '_';
    n += fmt_u32(p + n, hit);
    if (n < cap - 1)
        p[n++] = '.';
    if (n < cap - 1)
        p[n++] = 'b';
    if (n < cap - 1)
        p[n++] = 'i';
    if (n < cap - 1)
        p[n++] = 'n';
    p[n] = 0;
    return n;
}

static unsigned long read_startstack(void)
{
    char b[512];
    int f = open("/proc/self/stat", O_RDONLY);
    int n, i, fld = 0;
    unsigned long v = 0;
    if (f < 0)
        return 0;
    n = read(f, b, sizeof(b) - 1);
    close(f);
    if (n <= 0)
        return 0;
    b[n] = 0;
    for (i = 0; i < n; i++)
        if (b[i] == ')') {
            i++;
            break;
        }
    for (; i < n; i++)
        if (b[i] == ' ') {
            fld++;
            if (fld == 26) {
                v = strtoul(b + i + 1, 0, 10);
                break;
            }
        }
    return v;
}

static void segv(int sig, siginfo_t *si, void *ucp)
{
    ucontext_t *uc = (ucontext_t *)ucp;
    struct h4_hdr h = {0};
    char path[64];
    int fd, i;

    if (g_in_handler)
        _exit(139);
    g_in_handler = 1;
    g_hits++;

    for (i = 0; i < 8; i++)
        h.magic[i] = H5_MAGIC[i];
    h.version = 1;
    h.pid = (uint32_t)g_pid;
    h.hit = g_hits;
    h.sig = (uint32_t)sig;
    h.addr = (uint64_t)(uintptr_t)si->si_addr;
    if (uc) {
#if defined(__x86_64__)
        /* host-only plumbing test; device build is aarch64 */
        h.fault_address = (uint64_t)(uintptr_t)si->si_addr;
        h.pc = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
        h.sp = (uint64_t)uc->uc_mcontext.gregs[REG_RSP];
        h.x2 = h.x8 = h.x29 = h.x30 = 0;
        h.pstate = 0;
#else
        h.fault_address = (uint64_t)uc->uc_mcontext.fault_address;
        h.pc = (uint64_t)uc->uc_mcontext.pc;
        h.sp = (uint64_t)uc->uc_mcontext.sp;
        h.x2 = (uint64_t)uc->uc_mcontext.regs[2];
        h.x8 = (uint64_t)uc->uc_mcontext.regs[8];
        h.x29 = (uint64_t)uc->uc_mcontext.regs[29];
        h.x30 = (uint64_t)uc->uc_mcontext.regs[30];
        h.pstate = (uint64_t)uc->uc_mcontext.pstate;
#endif
    }
    h.stack_top = (uint64_t)g_stack_top;
    h.npages = NPAGES;
    h.ts = (uint64_t)time(NULL);

    fmt_path(path, sizeof(path), g_pid, g_hits);
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        (void)write(fd, &h, sizeof(h));
        if (g_stack_top) {
            for (i = 0; i < NPAGES; i++) {
                unsigned long va = g_stack_top - (unsigned long)(NPAGES - i) * PAGE;
                (void)write(fd, (void *)va, PAGE);
            }
        }
        close(fd);
    }
    g_in_handler = 0;
    if (g_ready)
        siglongjmp(g_jb, 1);
    _exit(139);
}


static int my_snprintf(char *buf, size_t n, const char *fmt, ...)
{
    va_list ap;
    struct { char pad[0x400]; va_list st; } s;
    int r;
    va_start(ap, fmt);
    va_copy(s.st, ap);
    r = vsnprintf(buf, n, fmt, s.st);
    va_end(s.st);
    va_end(ap);
    return r;
}

int main(void)
{
    char b[24];
    char msg[160];
    unsigned long i = 0;
    struct sigaction sa;
    stack_t ss;
    int n;

    g_pid = (int)getpid();
    g_stack_top = read_startstack();

    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = g_altstack;
    ss.ss_size = sizeof(g_altstack);
    ss.ss_flags = 0;
    (void)sigaltstack(&ss, NULL);

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = segv;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);

    /* no snprintf before the loop: it would create a va_list outside the
     * sigsetjmp window and the handler would have to _exit without a dump. */
    n = 0;
    {
        const char *pre = "VSURV5 pid=";
        while (*pre && n < (int)sizeof(msg) - 1) msg[n++] = *pre++;
        n += fmt_u32(msg + n, (unsigned int)g_pid);
        pre = " start_stack=0x";
        while (*pre && n < (int)sizeof(msg) - 1) msg[n++] = *pre++;
        n += fmt_hex(msg + n, g_stack_top);
        pre = " npages=";
        while (*pre && n < (int)sizeof(msg) - 1) msg[n++] = *pre++;
        n += fmt_u32(msg + n, NPAGES);
        if (n < (int)sizeof(msg) - 1) msg[n++] = 10;
    }
    (void)write(1, msg, n);

    for (;;) {
        if (sigsetjmp(g_jb, 1) == 0) {
            g_ready = 1;
            my_snprintf(b, sizeof(b), "%ld", (long)i);
            i++;
        } else {
            g_ready = 1;
        }
    }
    return 0;
}
