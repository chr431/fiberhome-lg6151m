/* oneoff: static DRAM/CPU integrity probe for the LG6151M (aarch64 musl static).
 *
 * Allocates a large anonymous mapping, fills it with a seed-dependent pattern,
 * verifies it, and repeats. Also checksums the buffer with two independent
 * methods (byte loop vs 64-bit words) to catch CPU/ALU faults. Any mismatch is
 * printed with the address, expected and observed values.
 *
 * Usage: memtest [size_mb] [passes]
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static uint64_t lcg(uint64_t *s) { *s = *s * 6364136223846793005ULL + 1442695040888963407ULL; return *s; }

static uint64_t sum_bytes(const unsigned char *p, size_t n)
{
    uint64_t s = 0;
    for (size_t i = 0; i < n; i++) s = s * 131 + p[i];
    return s;
}

static uint64_t sum_words(const unsigned char *p, size_t n)
{
    uint64_t s = 0;
    for (size_t i = 0; i + 8 <= n; i += 8) {
        uint64_t v;
        memcpy(&v, p + i, 8);
        s = s * 131 + v;
    }
    return s;
}

int main(int argc, char **argv)
{
    size_t mb = argc > 1 ? strtoul(argv[1], 0, 10) : 256;
    int passes = argc > 2 ? atoi(argv[2]) : 3;
    size_t n = mb << 20;
    unsigned char *p = mmap(0, n, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 2; }
    printf("memtest: %zu MB, %d passes, pid=%d\n", mb, passes, (int)getpid());
    fflush(stdout);

    int bad = 0;
    for (int pass = 0; pass < passes; pass++) {
        uint64_t s = 0x123456789abcdefULL ^ (uint64_t)pass;
        for (size_t i = 0; i < n; i += 8) {
            uint64_t v = lcg(&s);
            memcpy(p + i, &v, 8);
        }
        s = 0x123456789abcdefULL ^ (uint64_t)pass;
        for (size_t i = 0; i < n; i += 8) {
            uint64_t want = lcg(&s), got;
            memcpy(&got, p + i, 8);
            if (got != want) {
                if (bad < 10)
                    printf("MISMATCH pass=%d off=%zu want=%016llx got=%016llx\n",
                           pass, i, (unsigned long long)want, (unsigned long long)got);
                bad++;
            }
        }
        uint64_t a = sum_bytes(p, n), b = sum_words(p, n);
        printf("pass %d: mismatches=%d sum_bytes=%016llx sum_words=%016llx%s\n",
               pass, bad, (unsigned long long)a, (unsigned long long)b,
               (a != b) ? "  ALU-DIVERGENCE" : "");
        fflush(stdout);
    }
    munmap(p, n);
    printf("memtest done: %d mismatch(es)\n", bad);
    return bad ? 1 : 0;
}
