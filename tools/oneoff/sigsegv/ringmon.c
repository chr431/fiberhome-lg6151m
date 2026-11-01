// SPDX-License-Identifier: GPL-2.0
// ringmon -- userspace DD-bit + final-w0 monitor for MTK EDMA rings (read-only /dev/mem).
//   ringmon <ring_pa_hex> <entries> <seconds>
// Repeatedly preads the whole ring, counts w1 bit31 (DD) transients as a liveness
// control, then prints the last-seen w0 (buffer PA) per slot. One-shot tool (A4).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <ring_pa_hex> <entries> <seconds>\n", argv[0]); return 2; }
    unsigned long long pa = strtoull(argv[1], 0, 16);
    int entries = atoi(argv[2]);
    int secs = atoi(argv[3]);
    int fd = open("/dev/mem", O_RDONLY);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    size_t len = (size_t)entries * 32;
    unsigned char *buf = malloc(len);
    unsigned int *seen = calloc(entries, sizeof(unsigned int));
    if (!buf || !seen) { fprintf(stderr, "oom\n"); return 1; }
    unsigned long long scans = 0, dd_scans = 0, dd_total = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t0 = ts.tv_sec + ts.tv_nsec / 1e9;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &ts);
        if (ts.tv_sec + ts.tv_nsec / 1e9 - t0 >= secs) break;
        ssize_t n = pread(fd, buf, len, (off_t)pa);
        if (n != (ssize_t)len) { fprintf(stderr, "pread rc=%zd\n", n); break; }
        scans++;
        int any = 0;
        for (int i = 0; i < entries; i++) {
            unsigned int w0, w1;
            memcpy(&w0, buf + i * 32, 4);
            memcpy(&w1, buf + i * 32 + 4, 4);
            if (w1 & 0x80000000u) { dd_total++; any = 1; }
            seen[i] = w0;
        }
        if (any) dd_scans++;
    }
    close(fd);
    printf("ring_pa=0x%llx entries=%d seconds=%d scans=%u dd_scans=%u dd_total=%u.%u\n",
           pa, entries, secs, (unsigned)scans, (unsigned)dd_scans,
           (unsigned)(dd_total >> 32), (unsigned)dd_total);
    for (int i = 0; i < entries; i++) printf("W0 %d %08x\n", i, seen[i]);
    return 0;
}
