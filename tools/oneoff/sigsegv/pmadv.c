/* pmadv.c -- minimal process_madvise(2) wrapper (backup tool for the writer hunt).
 *
 * Why: process_madvise() lets us drop/age ONE page of ANOTHER process without
 * ptrace and without touching its registers -- the cheapest way to make a
 * victim's slot page "missing" so a writer must re-fault it (dropwatch-style),
 * or to page it out for a PA/VA experiment.
 *
 * aarch64 syscall numbers (asm-generic): pidfd_open = 434, process_madvise = 440.
 * Needs the same privilege as ptrace (PTRACE_MODE_READ_FSCREDS) and, on some
 * kernels, CAP_SYS_NICE for MADV_PAGEOUT/MADV_COLD.
 *
 * Usage:
 *   pmadv PID ADDR LEN BEHAV [loops] [period_ms]
 *     BEHAV = dontneed | pageout | cold | free | discard | normal
 *   pmadv --selftest            # advise our own heap page (must return LEN)
 * Prints one line per call (rc/errno) plus a summary; exit 2 on syscall error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#ifndef __NR_pidfd_open
#define __NR_pidfd_open 434
#endif
#ifndef __NR_process_madvise
#define __NR_process_madvise 440
#endif

static int behav_of(const char *s)
{
    if (!strcmp(s, "dontneed")) return 4;    /* MADV_DONTNEED  */
    if (!strcmp(s, "pageout"))  return 21;   /* MADV_PAGEOUT   */
    if (!strcmp(s, "cold"))     return 20;   /* MADV_COLD      */
    if (!strcmp(s, "free"))     return 8;    /* MADV_FREE      */
    if (!strcmp(s, "discard"))  return 9;    /* MADV_DISCARD   */
    if (!strcmp(s, "normal"))   return 0;    /* MADV_NORMAL    */
    return -1;
}

static long do_advise(int pidfd, unsigned long addr, size_t len, int adv)
{
    struct iovec iov;
    iov.iov_base = (void *)(uintptr_t)addr;
    iov.iov_len  = len;
    return syscall(__NR_process_madvise, pidfd, &iov, 1UL, adv, 0UL);
}

int main(int argc, char **argv)
{
    int pidfd, adv, loops = 1, period_ms = 0, i, bad = 0;
    unsigned long addr;
    size_t len;
    long rc;

    if (argc >= 2 && !strcmp(argv[1], "--selftest")) {
        void *p = malloc(4096);
        if (!p) { perror("malloc"); return 2; }
        memset(p, 0x5a, 4096);
        pidfd = (int)syscall(__NR_pidfd_open, getpid(), 0UL);
        if (pidfd < 0) { printf("SELFTEST pidfd_open FAIL errno=%d (%s)\n", errno, strerror(errno)); return 2; }
        rc = do_advise(pidfd, (unsigned long)(uintptr_t)p, 4096, 4);
        printf("SELFTEST self dontneed rc=%ld errno=%d (%s) expect_rc=4096\n", rc, rc < 0 ? errno : 0, rc < 0 ? strerror(errno) : "ok");
        if (rc != 4096) return 2;
        printf("SELFTEST PASS\n");
        return 0;
    }
    if (argc < 5) {
        fprintf(stderr, "usage: %s PID ADDR LEN BEHAV [loops] [period_ms]\n"
                        "       %s --selftest\n", argv[0], argv[0]);
        return 2;
    }
    pidfd = (int)syscall(__NR_pidfd_open, (pid_t)atoi(argv[1]), 0UL);
    if (pidfd < 0) { printf("ERR pidfd_open pid=%s errno=%d (%s)\n", argv[1], errno, strerror(errno)); return 2; }
    addr = strtoul(argv[2], 0, 0);
    len  = (size_t)strtoul(argv[3], 0, 0);
    adv  = behav_of(argv[4]);
    if (adv < 0) { fprintf(stderr, "unknown behavior %s\n", argv[4]); return 2; }
    if (argc > 5) loops = atoi(argv[5]);
    if (argc > 6) period_ms = atoi(argv[6]);
    if (loops < 1) loops = 1;
    printf("START pidfd=%d pid=%s addr=0x%lx len=%zu behav=%s(%d) loops=%d period_ms=%d\n",
           pidfd, argv[1], addr, len, argv[4], adv, loops, period_ms);
    for (i = 0; i < loops; i++) {
        rc = do_advise(pidfd, addr, len, adv);
        if (rc < 0) { bad++; printf("CALL i=%d rc=-1 errno=%d (%s)\n", i, errno, strerror(errno)); }
        else printf("CALL i=%d rc=%ld\n", i, rc);
        if (period_ms > 0 && i + 1 < loops) {
            struct timespec ts = { period_ms / 1000, (long)(period_ms % 1000) * 1000000L };
            nanosleep(&ts, 0);
        }
    }
    printf("SUMMARY calls=%d bad=%d\n", loops, bad);
    close(pidfd);
    return bad ? 2 : 0;
}
