/* ipdump.c -- dump a fixed user VA from a short-lived child at exit.
 *
 * P-1 from the 2026-10-30 ip report: run "ip -4 addr show" under ptrace,
 * stop at PTRACE_EVENT_EXIT, read ip's .bss filter region (VA 0x10f2b38,
 * 0x180 bytes) before the mm is torn down, and write it to a file.
 *
 * Usage:
 *   ipdump <va> <out> <prog> [args...]
 * Example:
 *   ipdump 0x10f2b38 /data/repro/ipf_1.bin /data/gw/bin/ip -4 addr show
 *
 * The child is our own ip; this is a read-only ptrace observation.
 * Build: zig cc -target aarch64-linux-musl -static -O2 -o ipdump ipdump.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    unsigned long va;
    const char *out;
    pid_t pid;
    int status;
    unsigned char buf[0x180];
    int got = 0;

    if (argc < 5) {
        fprintf(stderr, "usage: %s <va> <out> <prog> [args...]\n", argv[0]);
        return 2;
    }
    va = strtoul(argv[1], NULL, 0);
    out = argv[2];

    pid = fork();
    if (pid == 0) {
        ptrace(PTRACE_TRACEME, 0, 0, 0);
        execv(argv[3], &argv[3]);
        _exit(127);
    }
    if (pid < 0) {
        perror("fork");
        return 1;
    }

    if (waitpid(pid, &status, 0) < 0)
        return 1;
    ptrace(PTRACE_SETOPTIONS, pid, 0, PTRACE_O_TRACEEXIT);
    ptrace(PTRACE_CONT, pid, 0, 0);

    for (;;) {
        if (waitpid(pid, &status, 0) < 0)
            break;
        if (WIFEXITED(status) || WIFSIGNALED(status))
            break;
        if (!WIFSTOPPED(status))
            continue;
        if (WSTOPSIG(status) == SIGTRAP &&
            (status >> 8) == (SIGTRAP | (PTRACE_EVENT_EXIT << 8))) {
            struct iovec local = { buf, sizeof(buf) };
            struct iovec remote = { (void *)va, sizeof(buf) };
            ssize_t n = process_vm_readv(pid, &local, 1, &remote, 1, 0);
            if (n > 0) {
                int fd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (fd >= 0) {
                    ssize_t w = write(fd, buf, (size_t)n);
                    (void)w;
                    close(fd);
                    got = 1;
                }
            }
            ptrace(PTRACE_CONT, pid, 0, 0);
            break;
        }
        ptrace(PTRACE_CONT, pid, 0, WSTOPSIG(status));
    }
    return got ? 0 : 1;
}
