/* coreaddr.c v1.0 -- extract fault address (FAR) and PC from an ELF core head.
 *
 * Usage: coreaddr <core-or-notehead-file>
 *   prints "far=0x..." / "pc=0x..." (one per line) for what it found,
 *   exit 0 if at least one was parsed, exit 1 otherwise.
 *
 * Purpose (A1 far-infra): ne_events.tsv needs fault addr + PC per NE so the
 * "did the 32B record land on a live pointer" (lethality) alignment can run.
 * arm64 user fault lines are pr_info and never reach console/syslog on this
 * image, so the notes of the core itself are the authoritative source.
 *
 * Offsets are NOT guessed: they were verified against real device note heads
 * (2026-11-01, cores/raw note snapshots) and match tools/oneoff/sigsegv/
 * core_scan.py, the validated parser:
 *   - NT_SIGINFO (type 0x53494749, name "CORE"): si_signo@0 si_errno@4
 *     si_code@8, si_addr@16 (LP64 sigfault layout).
 *   - NT_PRSTATUS (type 1, name "CORE"): pr_reg base = note+112; aarch64
 *     user_regs_struct order = x0..x30, sp, pc, pstate -> pc = base+32*8.
 *     The FIRST NT_PRSTATUS is the faulting thread (kernel fills it before
 *     per-thread notes); its pr_cursig@12 also cross-checks the signal.
 *
 * The file may be a truncated core head (core_meta keeps a 8 KiB note-head
 * snapshot): parsing is bounded by the file size and simply fails (exit 1)
 * when the needed note does not fit -- the caller then writes empty columns.
 *
 * Build (static aarch64 musl): see tools/build_coreaddr.sh (zig cc).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define NT_PRSTATUS 1
#define NT_SIGINFO  0x53494749u
#define PRSTATUS_REG_BASE 112
#define REG_PC_IDX        32          /* x0..x30=0..30, sp=31, pc=32 */
#define MAX_FILE   (16 * 1024 * 1024) /* notes live in the head; refuse huge */

static unsigned char buf[MAX_FILE];

int main(int argc, char **argv)
{
    const char *path;
    int fd;
    ssize_t n, got = 0;
    uint64_t e_phoff;
    uint16_t e_phentsize, e_phnum;
    int i, found = 0;

    if (argc != 2) {
        fprintf(stderr, "usage: %s <core-or-notehead-file>\n", argv[0]);
        return 2;
    }
    path = argv[1];
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "coreaddr: open %s: %s\n", path, strerror(errno));
        return 1;
    }
    while (got < (int)sizeof(buf)) {
        n = read(fd, buf + got, sizeof(buf) - (size_t)got);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "coreaddr: read %s: %s\n", path, strerror(errno));
            close(fd);
            return 1;
        }
        if (n == 0)
            break;
        got += (int)n;
        if (got > (int)sizeof(buf))
            break;
    }
    close(fd);

    if (got < 64 || memcmp(buf, "\x7f""ELF", 4) != 0 || buf[4] != 2 /*ELFCLASS64*/) {
        fprintf(stderr, "coreaddr: %s: not an ELF64 core head\n", path);
        return 1;
    }

    e_phoff = 0;
    for (i = 0; i < 8; i++)
        e_phoff |= (uint64_t)buf[32 + i] << (8 * i);
    e_phentsize = (uint16_t)(buf[54] | (buf[55] << 8));
    e_phnum = (uint16_t)(buf[56] | (buf[57] << 8));
    if (e_phentsize < 56 || e_phnum > 128 || e_phoff + (uint64_t)e_phnum * e_phentsize > (uint64_t)got) {
        fprintf(stderr, "coreaddr: %s: bad program header table\n", path);
        return 1;
    }

    for (i = 0; i < e_phnum && !found; i++) {
        unsigned char *ph = buf + e_phoff + (uint32_t)i * e_phentsize;
        uint64_t p_offset, p_filesz;
        int j;
        if (!(ph[0] == 4 && ph[1] == 0 && ph[2] == 0 && ph[3] == 0)) /* PT_NOTE */
            continue;
        p_offset = p_filesz = 0;
        for (j = 0; j < 8; j++) {
            p_offset |= (uint64_t)ph[8 + j] << (8 * j);   /* p_offset  @8  */
            p_filesz |= (uint64_t)ph[32 + j] << (8 * j);  /* p_filesz  @32 */
        }
        if (p_offset >= (uint64_t)got)
            continue;
        {
            uint64_t p = p_offset;
            uint64_t end = p_offset + p_filesz;
            if (end > (uint64_t)got)
                end = (uint64_t)got; /* truncated head: parse what is there */
            while (p + 12 <= end) {
                uint32_t nsz, dsz, ntype;
                uint64_t dstart;
                nsz = (uint32_t)(buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16) | ((uint32_t)buf[p + 3] << 24));
                dsz = (uint32_t)(buf[p + 4] | (buf[p + 5] << 8) | (buf[p + 6] << 16) | ((uint32_t)buf[p + 7] << 24));
                ntype = (uint32_t)(buf[p + 8] | (buf[p + 9] << 8) | (buf[p + 10] << 16) | ((uint32_t)buf[p + 11] << 24));
                dstart = p + 12 + ((nsz + 3u) & ~3u);
                if (dstart > end)
                    break;
                if (nsz >= 5 && dstart >= 5 &&
                    memcmp(buf + p + 12, "CORE", 4) == 0) {
                    uint64_t avail = end - dstart;
                    if (ntype == NT_SIGINFO && dsz >= 24 && avail >= 24) {
                        uint64_t addr = 0;
                        int k;
                        for (k = 0; k < 8; k++)
                            addr |= (uint64_t)buf[dstart + 16 + k] << (8 * k);
                        printf("far=0x%llx\n", (unsigned long long)addr);
                        found |= 1;
                    } else if (ntype == NT_PRSTATUS && !(found & 2) &&
                               dsz >= PRSTATUS_REG_BASE + (REG_PC_IDX + 1) * 8 &&
                               avail >= PRSTATUS_REG_BASE + (REG_PC_IDX + 1) * 8) {
                        uint64_t pc = 0;
                        int k;
                        uint64_t off = dstart + PRSTATUS_REG_BASE + (uint64_t)REG_PC_IDX * 8;
                        for (k = 0; k < 8; k++)
                            pc |= (uint64_t)buf[off + k] << (8 * k);
                        printf("pc=0x%llx\n", (unsigned long long)pc);
                        found |= 2;
                    }
                }
                p = dstart + ((dsz + 3u) & ~3u);
                if (found == 3)
                    break;
            }
        }
        if (found == 3)
            break;
    }

    if (!found) {
        fprintf(stderr, "coreaddr: %s: no NT_SIGINFO/NT_PRSTATUS in note head\n", path);
        return 1;
    }
    return 0;
}
