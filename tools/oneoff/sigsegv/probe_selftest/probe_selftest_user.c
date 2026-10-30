/* probe_selftest_user.c -- user side of the positive controls.
 *
 * Build: zig cc -target aarch64-linux-musl -static -O2 -o probe_selftest_user probe_selftest_user.c
 * Run:   ./probe_selftest_user pf|cfu|uw
 *
 * Prints the VA; then writes "mode VA" to /proc/probe_selftest.  Check dmesg
 * for the expected cth/uw line.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "pf";
    void *p;
    char cmd[96];
    int fd;

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif
    /* fixed VA so cth can be loaded with a known pf_lo/pf_hi before the test */
    p = mmap((void *)0x7000000000UL, 4096, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (p == MAP_FAILED)
        p = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    memset(p, 0x41, 4096);
    mlock(p, 4096);

    if (!strcmp(mode, "pf")) {
        if (mprotect(p, 4096, PROT_READ) != 0) {
            perror("mprotect");
            return 1;
        }
    }

    printf("mode=%s va=%p\n", mode, p);
    fd = open("/proc/probe_selftest", O_WRONLY);
    if (fd < 0) {
        perror("open /proc/probe_selftest");
        return 1;
    }
    snprintf(cmd, sizeof(cmd), "%s %p", mode, p);
    if (write(fd, cmd, strlen(cmd)) < 0) {
        perror("write");
        close(fd);
        return 1;
    }
    close(fd);
    if (!strcmp(mode, "uw"))
        sleep(1);
    return 0;
}
