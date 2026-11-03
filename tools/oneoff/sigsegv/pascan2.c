/* pascan2 -- scan physical memory via /dev/mem for a 32-bit or 64-bit value.
 *
 * usage: pascan2 <start_pa_hex> <end_pa_hex> <value_hex> <4|8> [salt]
 *
 * Differences from pascan v1 (D25):
 *   - 4-byte width support (truncated-address search) at 4B stride;
 *   - per-page readability accounting (unreadable pages are NOT "zero hits");
 *   - 16-byte context around every hit (classify true 32-bit field vs low half
 *     of a 64-bit pointer);
 *   - self-pollution flag: a hit page containing the tool name or the ASCII
 *     value string is the scanner's own argv page;
 *   - optional salt: callers run the same scan twice with different salt
 *     lengths; self-frame hits shift, real RAM structures do not.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#define CHUNK (1024 * 1024)
static unsigned char buf[CHUNK];

static int page_has(const unsigned char *hay, ssize_t n, const char *needle)
{
    size_t m = strlen(needle), i;
    if (m == 0 || (ssize_t)m > n)
        return 0;
    for (i = 0; i + m <= (size_t)n; i++)
        if (hay[i] == (unsigned char)needle[0] && memcmp(hay + i, needle, m) == 0)
            return 1;
    return 0;
}

static void print_ctx(unsigned long long pa, unsigned long long page,
                      unsigned long long off, const unsigned char *p,
                      ssize_t n, int width, int self)
{
    unsigned long long v4 = 0, v8 = 0, c0 = 0, c1 = 0;
    ssize_t j;
    for (j = 0; j < 4 && off + j < (unsigned long long)n; j++)
        v4 |= (unsigned long long)p[off + j] << (8 * j);
    for (j = 0; j < 8 && off + j < (unsigned long long)n; j++)
        v8 |= (unsigned long long)p[off + j] << (8 * j);
    for (j = 0; j < 8; j++) {
        long long k = (long long)off - 8 + j;
        if (k >= 0 && k < n)
            c0 |= (unsigned long long)p[k] << (8 * j);
        k = (long long)off + j;
        if (k >= 0 && k < n)
            c1 |= (unsigned long long)p[k] << (8 * j);
    }
    printf("HIT pa=0x%llx page=0x%llx off=0x%llx w=%d v4=0x%08llx v8=0x%016llx "
           "pre=0x%016llx post=0x%016llx self=%d\n",
           pa, page, off, width, v4 & 0xffffffffULL, v8, c0, c1, self);
}

static void scan_page(const unsigned char *p, ssize_t n, unsigned long long page,
                      int width, unsigned long long tgt,
                      unsigned long long *hits, unsigned long long *printed,
                      unsigned long long cap, const char *valstr)
{
    ssize_t i;
    int self_page = page_has(p, n, "pascan2") || page_has(p, n, valstr);
    if (width == 4) {
        for (i = 0; i + 4 <= n; i += 4) {
            uint32_t v;
            memcpy(&v, p + i, 4);
            if ((unsigned long long)v == (tgt & 0xffffffffULL)) {
                (*hits)++;
                if (*printed < cap) {
                    print_ctx(page + i, page, (unsigned long long)i, p, n, 4, self_page);
                    (*printed)++;
                }
            }
        }
    } else {
        for (i = 0; i + 8 <= n; i += 8) {
            unsigned long long v;
            memcpy(&v, p + i, 8);
            if (v == tgt) {
                (*hits)++;
                if (*printed < cap) {
                    print_ctx(page + i, page, (unsigned long long)i, p, n, 8, self_page);
                    (*printed)++;
                }
            }
        }
    }
}

int main(int argc, char **argv)
{
    unsigned long long start, end, tgt, pa;
    unsigned long long pages_read = 0, pages_bad = 0, hits = 0, printed = 0;
    int width, fd;
    const unsigned long long CAP = 512;

    if (argc < 5) {
        fprintf(stderr, "usage: %s <start_hex> <end_hex> <value_hex> <4|8> [salt]\n", argv[0]);
        return 2;
    }
    start = strtoull(argv[1], NULL, 16);
    end   = strtoull(argv[2], NULL, 16);
    tgt   = strtoull(argv[3], NULL, 16);
    width = atoi(argv[4]);
    if (width != 4 && width != 8) {
        fprintf(stderr, "width must be 4 or 8\n");
        return 2;
    }
    printf("SCAN start=0x%llx end=0x%llx tgt=0x%llx width=%d salt=%s\n",
           start, end, tgt, width, argc > 5 ? argv[5] : "-");

    fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    for (pa = start & ~0xFFFULL; pa < end; pa += CHUNK) {
        unsigned long long want = end - pa;
        ssize_t n;
        if (want > CHUNK) want = CHUNK;
        n = pread(fd, buf, (size_t)want, (off_t)pa);
        if (n <= 0) {
            /* per-page fallback so unreadable pages are counted honestly */
            unsigned long long q;
            for (q = 0; q < want; q += 4096) {
                ssize_t m = pread(fd, buf, 4096, (off_t)(pa + q));
                if (m <= 0) { pages_bad++; continue; }
                pages_read++;
                scan_page(buf, m, pa + q, width, tgt, &hits, &printed, CAP, argv[3]);
            }
            continue;
        }
        pages_read += (unsigned long long)n / 4096;
        if ((unsigned long long)n % 4096)
            pages_read++;
        {
            unsigned long long q;
            for (q = 0; q < (unsigned long long)n; q += 4096) {
                ssize_t m = (ssize_t)((unsigned long long)n - q);
                if (m > 4096) m = 4096;
                scan_page(buf + q, m, pa + q, width, tgt, &hits, &printed, CAP, argv[3]);
            }
        }
    }
    close(fd);
    printf("SUMMARY pages_read=%llu pages_unreadable=%llu hits_total=%llu printed=%llu\n",
           pages_read, pages_bad, hits, printed);
    return 0;
}
