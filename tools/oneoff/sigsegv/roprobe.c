/* roprobe.c -- U-E1/M2 positive control: a control process self-writes its own
 * mprotect(PROT_READ) page through a syscall, so the kernel's copy_to_user
 * faults and the extable path (fixup_exception) must run in THIS process's mm.
 *
 * The harness starts it, reads "ROPROBE pid=.. page=..", insmods fxhook_v6 with
 * vpid=<pid> lo=<page> hi=<page+4096>, then lets it read /dev/zero into the RO
 * page every 5 s.  Each read must produce one fixup record with
 * comm=roprobe, far=<page>, pc inside __arch_copy_to_user, lr in the caller.
 *
 * Build: zig cc -target aarch64-linux-musl -O2 -static -o roprobe roprobe.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

static int mytid(void) { return (int)syscall(178); }

int main(int argc, char **argv)
{
    int secs = (argc > 1) ? atoi(argv[1]) : 60;
    long pg = sysconf(_SC_PAGESIZE);
    unsigned char *p;
    int fd, i;

    if (pg <= 0) pg = 4096;
    p = mmap(NULL, (size_t)pg, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 2; }
    memset(p, 0x41, (size_t)pg);
    if (mprotect(p, (size_t)pg, PROT_READ) != 0) { perror("mprotect"); return 2; }
    fd = open("/dev/zero", O_RDONLY);
    if (fd < 0) { perror("open /dev/zero"); return 2; }

    printf("ROPROBE pid=%d tid=%d page=0x%lx size=%ld secs=%d\n",
           (int)getpid(), mytid(), (unsigned long)(uintptr_t)p, pg, secs);
    fflush(stdout);

    for (i = 0; i < secs / 5; i++) {
        ssize_t n;
        sleep(5);
        errno = 0;
        n = read(fd, p, 32);          /* kernel copy_to_user -> RO fault -> fixup */
        printf("ROPROBE read i=%d rc=%zd errno=%d\n", i, n, errno);
        fflush(stdout);
    }
    close(fd);
    return 0;
}
