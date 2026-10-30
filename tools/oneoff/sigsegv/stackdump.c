/* stackdump.c -- fault-time stack window snapshot for core_meta.sh.
 *
 * Usage: stackdump <pid> <out> [pages]
 *
 * The crashing process is stopped by the kernel while the core_pattern helper
 * runs, so /proc/<pid>/mem is a fault-time view.  We dump the last N pages of
 * the [stack] VMA (default 16 = 64 KiB).  The vsurv3 va_list is at
 * start_stack-0x380, so 16 pages is ample.
 *
 * Output:
 *   struct sd_hdr (48 bytes) + u64 present_bitmap + pages*4096 bytes
 *   present bit i = page i was readable; unreadable pages are zero-filled.
 *
 * Build (static aarch64 musl):
 *   aarch64-linux-musl-gcc -static -O2 -o stackdump stackdump.c
 * or:
 *   zig cc -target aarch64-linux-musl -static -O2 -o stackdump stackdump.c
 *
 * This helper is deliberately simple: it runs from core_meta.sh, not from a
 * signal handler, so stdio is acceptable.  It must never block the core dump
 * for long: 64 KiB is a few pread calls.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SD_MAGIC "SDMPv1"
#define SD_VERSION 1
#define SD_MAX_PAGES 64
#define SD_PAGE 4096

struct sd_hdr {
    char magic[8];
    uint32_t version;
    uint32_t pid;
    uint64_t start;
    uint64_t end;
    uint32_t pages;
    uint32_t reserved;
    uint64_t ts;
} __attribute__((packed));

static int find_stack(pid_t pid, uint64_t *start, uint64_t *end)
{
    char path[64], line[512];
    FILE *f;
    int found = 0;

    snprintf(path, sizeof(path), "/proc/%d/maps", (int)pid);
    f = fopen(path, "r");
    if (!f)
        return -1;
    while (fgets(line, sizeof(line), f)) {
        unsigned long long s, e;
        if (!strstr(line, "[stack]"))
            continue;
        if (sscanf(line, "%llx-%llx", &s, &e) == 2) {
            *start = (uint64_t)s;
            *end = (uint64_t)e;
            found = 1;
            break;
        }
    }
    fclose(f);
    if (found)
        return 0;

    /* fallback: /proc/<pid>/stat field 28 = startstack */
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    f = fopen(path, "r");
    if (!f)
        return -1;
    if (fgets(line, sizeof(line), f)) {
        char *p = strrchr(line, ')');
        int i;
        if (p) {
            p++;
            for (i = 1; i <= 28 && p; i++) {
                while (*p == ' ')
                    p++;
                if (i == 28) {
                    *end = strtoull(p, NULL, 10);
                    *start = *end;
                    found = 1;
                    break;
                }
                p = strchr(p, ' ');
                if (!p)
                    break;
            }
        }
    }
    fclose(f);
    return found ? 0 : -1;
}

int main(int argc, char **argv)
{
    pid_t pid;
    int pages = 16;
    uint64_t map_start = 0, map_end = 0, start, end;
    char path[64];
    int memfd, outfd;
    struct sd_hdr hdr;
    uint64_t present = 0;
    unsigned char *buf;
    int i, nread = 0;

    if (argc < 3) {
        fprintf(stderr, "usage: %s <pid> <out> [pages]\n", argv[0]);
        return 2;
    }
    pid = (pid_t)strtol(argv[1], NULL, 10);
    if (argc > 3)
        pages = atoi(argv[3]);
    if (pages <= 0 || pages > SD_MAX_PAGES)
        pages = 16;

    if (find_stack(pid, &map_start, &map_end) != 0) {
        fprintf(stderr, "stackdump: no [stack] for pid %d\n", (int)pid);
        return 1;
    }
    end = map_end;
    start = (end > (uint64_t)pages * SD_PAGE) ? end - (uint64_t)pages * SD_PAGE : map_start;
    if (start < map_start)
        start = map_start;

    buf = calloc((size_t)pages, SD_PAGE);
    if (!buf)
        return 1;

    snprintf(path, sizeof(path), "/proc/%d/mem", (int)pid);
    memfd = open(path, O_RDONLY);
    if (memfd < 0) {
        fprintf(stderr, "stackdump: open %s: %s\n", path, strerror(errno));
        free(buf);
        return 1;
    }
    for (i = 0; i < pages; i++) {
        uint64_t va = start + (uint64_t)i * SD_PAGE;
        ssize_t n;
        if (va + SD_PAGE > end)
            break;
        n = pread(memfd, buf + (size_t)i * SD_PAGE, SD_PAGE, (off_t)va);
        if (n == (ssize_t)SD_PAGE) {
            present |= (1ULL << i);
            nread++;
        } else {
            memset(buf + (size_t)i * SD_PAGE, 0, SD_PAGE);
        }
    }
    close(memfd);

    memset(&hdr, 0, sizeof(hdr));
    memcpy(hdr.magic, SD_MAGIC, 7);
    hdr.version = SD_VERSION;
    hdr.pid = (uint32_t)pid;
    hdr.start = start;
    hdr.end = end;
    hdr.pages = (uint32_t)pages;
    hdr.ts = (uint64_t)time(NULL);

    outfd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (outfd < 0) {
        fprintf(stderr, "stackdump: open %s: %s\n", argv[2], strerror(errno));
        free(buf);
        return 1;
    }
    if (write(outfd, &hdr, sizeof(hdr)) != (ssize_t)sizeof(hdr) ||
        write(outfd, &present, sizeof(present)) != (ssize_t)sizeof(present) ||
        write(outfd, buf, (size_t)pages * SD_PAGE) != (ssize_t)((size_t)pages * SD_PAGE)) {
        fprintf(stderr, "stackdump: write: %s\n", strerror(errno));
        close(outfd);
        free(buf);
        return 1;
    }
    close(outfd);
    free(buf);
    fprintf(stderr, "stackdump: pid=%d pages=%d readable=%d start=%#llx end=%#llx\n",
            (int)pid, pages, nread, (unsigned long long)start, (unsigned long long)end);
    return 0;
}
