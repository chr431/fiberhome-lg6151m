/* arrwatch -- high-frequency watch for page PAs inside a physical range.
 *
 * usage: arrwatch <start_pa_hex> <end_pa_hex> <pa_list_file> <interval_ms> [max_iter]
 *
 * Reads /dev/mem [start,end) every interval_ms and searches for any u32 value
 * equal to one of the PAs listed in pa_list_file (one hex PA per line, '#'
 * comments allowed).  Prints one HIT line per (iteration, PA) match plus a
 * heartbeat every 600 iterations.  Purpose (D26): catch *transient* page-pool
 * entries for canary stack pages that a 30 s dump cadence would miss.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

#define MAXPA 256
#define BUFMAX (4 * 1024 * 1024)
static unsigned char buf[BUFMAX];

static double uptime_s(void)
{
    FILE *f = fopen("/proc/uptime", "r");
    double v = 0;
    if (f) { if (fscanf(f, "%lf", &v) != 1) v = 0; fclose(f); }
    return v;
}

static int cmp_pa(const void *a, const void *b)
{
    unsigned long long x = *(const unsigned long long *)a;
    unsigned long long y = *(const unsigned long long *)b;
    return (x > y) - (x < y);
}

static int load_pas(const char *path, unsigned long long *pas)
{
    FILE *f = fopen(path, "r");
    char line[128];
    int n = 0;
    if (!f) return -1;
    while (fgets(line, sizeof(line), f) && n < MAXPA) {
        char *p = line;
        unsigned long long v;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == 0) continue;
        if (sscanf(p, "%llx", &v) == 1 && v)
            pas[n++] = v;
    }
    fclose(f);
    if (n > 0) qsort(pas, n, sizeof(pas[0]), cmp_pa);
    return n;
}

/* binary search: 1 if found */
static int has_pa(const unsigned long long *pas, int n, unsigned long long v)
{
    int lo = 0, hi = n - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (pas[mid] == v) return 1;
        if (pas[mid] < v) lo = mid + 1; else hi = mid - 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    unsigned long long start, end, pas[MAXPA];
    int interval, max_iter = 100000000, np, fd, it;
    size_t len;

    if (argc < 5) {
        fprintf(stderr, "usage: %s <start_hex> <end_hex> <pa_list_file> <interval_ms> [max_iter]\n", argv[0]);
        return 2;
    }
    start = strtoull(argv[1], NULL, 16);
    end   = strtoull(argv[2], NULL, 16);
    interval = atoi(argv[4]);
    if (argc > 5) max_iter = atoi(argv[5]);
    len = (size_t)(end - start);
    if (len > BUFMAX) { fprintf(stderr, "range too big\n"); return 2; }

    np = load_pas(argv[3], pas);
    if (np <= 0) { fprintf(stderr, "no PAs in %s\n", argv[3]); return 2; }
    printf("WATCH start=0x%llx end=0x%llx np=%d interval=%dms\n", start, end, np, interval);
    fflush(stdout);

    fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    for (it = 0; it < max_iter; it++) {
        ssize_t got = pread(fd, buf, len, (off_t)start);
        if (got <= 0) {
            printf("READFAIL up=%.2f it=%d\n", uptime_s(), it);
            fflush(stdout);
        } else {
            size_t off;
            int hit = 0;
            for (off = 0; off + 4 <= (size_t)got; off += 4) {
                uint32_t v;
                memcpy(&v, buf + off, 4);
                if ((v & 0xfff) == 0 && has_pa(pas, np, (unsigned long long)v)) {
                    printf("HIT up=%.2f it=%d pa=0x%x off=0x%llx\n",
                           uptime_s(), it, v, start + off);
                    hit = 1;
                }
            }
            if (hit) fflush(stdout);
            if (it % 600 == 0) {
                printf("HB up=%.2f it=%d\n", uptime_s(), it);
                fflush(stdout);
            }
        }
        usleep(interval * 1000);
    }
    close(fd);
    printf("DONE up=%.2f it=%d\n", uptime_s(), it);
    return 0;
}
