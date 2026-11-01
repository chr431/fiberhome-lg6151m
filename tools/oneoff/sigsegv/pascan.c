#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

/* pascan: scan physical memory via /dev/mem for an 8-byte value (page-aligned reads). */
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <start_pa_hex> <end_pa_hex> <target_hex>\n", argv[0]); return 2; }
    unsigned long long start = strtoull(argv[1], NULL, 16);
    unsigned long long end   = strtoull(argv[2], NULL, 16);
    unsigned long long tgt   = strtoull(argv[3], NULL, 16);
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    static unsigned char buf[4096];
    unsigned long long pa;
    int hits = 0; unsigned long pages = 0;
    for (pa = start & ~0xFFFULL; pa < end; pa += 4096) {
        ssize_t n = pread(fd, buf, 4096, (off_t)pa);
        pages++;
        if (n <= 0) continue;
        for (ssize_t i = 0; i + 8 <= n; i += 8) {
            unsigned long long v;
            memcpy(&v, buf + i, 8);
            if (v == tgt) {
                printf("HIT pa=0x%llx (page 0x%llx +0x%llx)\n", pa + i, pa, (unsigned long long)i);
                if (++hits >= 32) { close(fd); printf("pages=%lu hits=%d\n", pages, hits); return 0; }
            }
        }
    }
    close(fd);
    printf("pages=%lu hits=%d\n", pages, hits);
    return 0;
}
