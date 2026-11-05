/* uaprobe_victim.c -- U-A1 实验用"休眠式受害者"（静态 aarch64-musl，无 ucontext 依赖）
 *
 * 为什么是这个形状（与历史受害者 vsurv4/scanary 的差别见 EXPERIMENT_U-A1_RO_SLOT.md §6）：
 *   - 目标是**活 va_list 所在页**：本进程构造一层可变参帧，把 &ap 与 page(&ap) 自报出来；
 *   - 主线程随后**永不返回**（阻塞全信号 + pause 循环），因此该页可安全改成 PROT_READ；
 *   - 所有窗口动作（快照/mprotect/sleep/恢复 RW/dump）由**独立 helper 线程**在自己栈上完成。
 * 纪律：只动自己 mm 的权限位（C-174）；不插页、不改归属；不依赖 pagemap/kmsg。
 *
 * 用法：
 *   uaprobe_victim --mode rw|ro [--hold-ms N] [--depth D] [--dump F]
 *   uaprobe_victim --mode migrate --hold-ms N     (实验性：同 VA 换页后重建帧)
 * 输出：fd2 上 key=0x.. 逐字段 + 末行单行 TSV（字段见文档 §2）
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define PAGE 4096UL
#define MAX_DEPTH 64

static volatile unsigned long g_slot_va, g_page_va;
static volatile int   g_go, g_round = 1;
static int            g_ro, g_mig;
static long           g_hold_ms = 60000;
static char           g_dump[512] = "/tmp/uaprobe_page.bin";
static volatile int   g_main_pid;

static void emit(const char *k, unsigned long v)
{
    char b[96];
    int n = snprintf(b, sizeof b, "%s=0x%lx\n", k, v);
    if (n > 0) { ssize_t w = write(2, b, (size_t)n); (void)w; }
}

static uint64_t digest(const unsigned char *p, size_t n)
{
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

/* ---------- helper 线程：窗内全部动作都在它自己的栈上 ---------- */
static void *helper(void *arg)
{
    (void)arg;
    while (!g_go) { struct timespec t = {0, 1000000}; nanosleep(&t, 0); }

    unsigned long slot = g_slot_va, page = g_page_va, mp = 0, rr = 0, diff = 0;
    unsigned char *snap = malloc(PAGE);
    if (snap) memcpy(snap, (void *)page, PAGE);
    uint64_t d0 = snap ? digest(snap, PAGE) : 0;

    if (g_ro) { mp = (mprotect((void *)page, PAGE, PROT_READ) == 0) ? 0UL : (unsigned long)errno; }
    emit("mprotect_rc", mp);
    emit("slot_va_at_arm", slot);
    emit("page_va_at_arm", page);

    struct timespec ts = { g_hold_ms / 1000, (g_hold_ms % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) { }

    /* 窗末：**先恢复 RW 再 dump**（Lead 硬要求） */
    if (g_ro) { rr = (mprotect((void *)page, PAGE, PROT_READ | PROT_WRITE) == 0) ? 0UL : (unsigned long)errno; }
    emit("restore_rc", rr);

    int fd = open(g_dump, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) { ssize_t w = write(fd, (void *)page, PAGE); (void)w; close(fd); }
    unsigned char *now = malloc(PAGE);
    uint64_t d1 = 0;
    if (now) {
        memcpy(now, (void *)page, PAGE);
        d1 = digest(now, PAGE);
        if (snap) for (size_t i = 0; i < PAGE; i++) if (now[i] != snap[i]) diff++;
    }
    emit("digest_before", d0); emit("digest_after", d1); emit("bytes_changed", diff);
    emit("done", 1);
    {   /* 单行 TSV：pid mode slot page off mprotect restore digest0 digest1 changed round hold_ms */
        char t[320];
        int n = snprintf(t, sizeof t,
            "TSV\t%d\t%s\t0x%lx\t0x%lx\t0x%lx\t0x%lx\t0x%lx\t0x%lx\t0x%lx\t%lu\t%lu\t%lu\n",
            (int)(unsigned long)g_main_pid, g_ro ? "ro" : (g_mig ? "migrate" : "rw"),
            slot, page, slot - page, mp, rr, d0, d1, diff,
            (unsigned long)g_round, (unsigned long)g_hold_ms);
        if (n > 0) { ssize_t w = write(2, t, (size_t)n); (void)w; }
    }
    _exit(0);
    return 0;
}

static void deep(int depth, const char *fmt, ...);

/* 可变参持有者：只记录 &ap / page，然后**永不返回** */
static void holder(int depth, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    g_slot_va = (unsigned long)(uintptr_t)&ap;
    g_page_va = g_slot_va & ~(PAGE - 1);

    volatile unsigned long sink = 0;
    for (int i = 0; i < 4; i++) sink += (unsigned long)va_arg(ap, unsigned long);

    emit("round", (unsigned long)g_round);
    emit("depth", (unsigned long)depth);
    emit("slot_va", g_slot_va);
    emit("page_va", g_page_va);
    emit("page_off", g_slot_va - g_page_va);
    emit("mode_ro", (unsigned long)g_ro);
    emit("mode_migrate", (unsigned long)g_mig);

    if (g_mig && g_round == 1) {
        /* 实验性：同 VA 换页（MAP_FIXED => 新页/新 PA），随后重建帧 */
        void *r = mmap((void *)g_page_va, PAGE, PROT_READ | PROT_WRITE,
                       MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        emit("remap_ok", (r == (void *)g_page_va) ? 1UL : 0UL);
        g_round = 2;
        deep(8, "uaprobe2");      /* 新页上重建；不返回 */
    }

    /* 终点态：阻塞全部信号 + 永不返回（该页从此不被本进程触碰） */
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, 0);
    g_go = 1;
    for (;;) pause();
    va_end(ap); (void)fmt; (void)sink; (void)depth;
}

static void deep(int depth, const char *fmt, ...)
{
    if (depth <= 0) { holder(0, fmt, 1UL, 2UL, 3UL, 4UL); return; }
    deep(depth - 1, fmt);
}

int main(int argc, char **argv)
{
    int depth = 8;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
            const char *m = argv[++i];
            g_ro = !strcmp(m, "ro");
            g_mig = !strcmp(m, "migrate");
        } else if (!strcmp(argv[i], "--hold-ms") && i + 1 < argc) g_hold_ms = atol(argv[++i]);
        else if (!strcmp(argv[i], "--depth") && i + 1 < argc) { depth = atoi(argv[++i]); if (depth > MAX_DEPTH) depth = MAX_DEPTH; }
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) snprintf(g_dump, sizeof g_dump, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--help")) { printf("usage: %s --mode rw|ro|migrate --hold-ms N [--depth D] [--dump F]\n", argv[0]); return 0; }
    }
    g_main_pid = getpid();
    emit("pid", (unsigned long)getpid());
    pthread_t th;
    if (pthread_create(&th, 0, helper, 0) != 0) { fprintf(stderr, "pthread_create failed\n"); return 4; }
    deep(depth, "uaprobe");
    return 0;      /* 不会到达 */
}
