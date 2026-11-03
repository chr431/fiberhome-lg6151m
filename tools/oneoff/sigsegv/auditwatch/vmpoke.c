/* vmpoke.c -- positive-control trigger for the auditpoke EXIT rules.
 *
 * Forks a child, then performs against the CHILD's own stack:
 *   - N x process_vm_writev(32 B) onto a preset stack address
 *   - 1 x ptrace(PTRACE_ATTACH -> PTRACE_POKEDATA -> PTRACE_DETACH)
 * and verifies every write landed.  If the auditpoke rule is installed and
 * audit is enabled, each of these syscalls must produce a kmsg line:
 *   audit(...): ... arch=<arch> syscall=<NR> ... comm="vmpoke" ...
 * (syscall numbers: ptrace / process_vm_writev per audit_const.h.)
 *
 * Syscalls are issued through syscall() with explicit numbers from the
 * 5.15.134 tree (audit_const.h) so the audited numbers are exactly the ones
 * the rules cover.  PTRACE_* constants also from audit_const.h
 * (include/uapi/linux/ptrace.h of the device tree; aarch64 has no
 * GETREGS/SETREGS, only REGSET requests 0x4204/0x4205).
 *
 * usage: vmpoke [N] [gap_ms]      (default N=4, gap=300)
 * exit: 0 all writes verified; 1 setup failure; 2 verification failure.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>

#include "audit_const.h"

#define WRITE_LEN 32
#define POKE_WORD 0x706f6b65UL             /* "ekop" magic for POKEDATA */

struct target_blob {
    unsigned char wbuf[WRITE_LEN * 64];     /* process_vm_writev landing zone */
    unsigned long poked;                    /* POKEDATA landing word */
};

static long sys_pvm_writev(pid_t pid, const struct iovec *lio, unsigned long ln,
                           const struct iovec *rio, unsigned long rn)
{
    return syscall((long)NR_PROCESS_VM_WR, (long)pid, lio, ln, rio, rn, 0UL);
}

static long sys_ptrace(long req, long pid, void *addr, void *data)
{
    return syscall((long)NR_PTRACE, req, pid, addr, data);
}

int main(int argc, char **argv)
{
    int n = (argc >= 2) ? atoi(argv[1]) : 4;
    int gap_ms = (argc >= 3) ? atoi(argv[2]) : 300;
    if (n < 1 || n > 63) {
        fprintf(stderr, "vmpoke: N must be 1..63\n");
        return 1;
    }

    int addr_pipe[2], done_pipe[2];
    if (pipe(addr_pipe) < 0 || pipe(done_pipe) < 0) {
        perror("pipe");
        return 1;
    }

    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }

    if (pid == 0) {
        /* ---- child: publish target address, wait for 'D', verify ---- */
        struct target_blob t;
        memset(&t, 0, sizeof(t));
        unsigned long addr = (unsigned long)&t;
        if (write(addr_pipe[1], &addr, sizeof(addr)) != sizeof(addr))
            _exit(1);
        close(addr_pipe[0]); close(addr_pipe[1]);
        close(done_pipe[1]);
        char c = 0;
        ssize_t r;
        /* read restarts after ptrace stop/detach; loop for safety */
        while ((r = read(done_pipe[0], &c, 1)) == 0 || (r < 0 && errno == EINTR))
            ;
        if (r != 1 || c != 'D')
            _exit(1);
        close(done_pipe[0]);
        /* verify: each iteration wrote 32 B of per-iteration pattern */
        int ok = 0;
        for (int i = 0; i < n; i++) {
            unsigned char *p = t.wbuf + (size_t)i * WRITE_LEN;
            int good = 1;
            for (int b = 0; b < WRITE_LEN; b++)
                if (p[b] != (unsigned char)i)
                    good = 0;
            if (good)
                ok++;
        }
        int poke_ok = (t.poked == POKE_WORD);
        fprintf(stderr, "vmpoke[child %d]: pvm_writev verified %d/%d, "
                "ptrace POKEDATA word=%s\n", getpid(), ok, n,
                poke_ok ? "OK" : "MISMATCH");
        _exit((ok == n && poke_ok) ? 0 : 2);
    }

    /* ---- parent ---- */
    close(addr_pipe[1]);
    close(done_pipe[0]);
    unsigned long caddr = 0;
    if (read(addr_pipe[0], &caddr, sizeof(caddr)) != sizeof(caddr)) {
        fprintf(stderr, "vmpoke: no address from child\n");
        return 1;
    }
    close(addr_pipe[0]);
    printf("vmpoke: child pid=%d target stack addr=0x%lx "
           "(arch=%s syscalls: pvm_writev=%d ptrace=%d)\n",
           pid, caddr, ARCH_NAME, NR_PROCESS_VM_WR, NR_PTRACE);

    /* N x process_vm_writev, 32 B each, distinctive per-iteration pattern */
    for (int i = 0; i < n; i++) {
        unsigned char out[WRITE_LEN];
        memset(out, i & 0xff, sizeof(out));
        struct iovec l = { out, WRITE_LEN };
        struct iovec r = {
            (void *)(caddr + offsetof(struct target_blob, wbuf) +
                     (size_t)i * WRITE_LEN),
            WRITE_LEN
        };
        errno = 0;
        long rc = sys_pvm_writev(pid, &l, 1UL, &r, 1UL);
        printf("vmpoke[%d/%d]: process_vm_writev(32B -> child+%d) = %ld%s\n",
               i + 1, n, i * WRITE_LEN, rc, rc == WRITE_LEN ? "" : " FAILED");
        if (rc != WRITE_LEN)
            fprintf(stderr, "vmpoke: writev rc=%ld errno=%d (%s)\n", rc, errno,
                    strerror(errno));
        usleep((useconds_t)gap_ms * 1000);
    }

    /* 1 x ptrace POKEDATA to the child's stack */
    errno = 0;
    long rc = sys_ptrace(PT_ATTACH, pid, NULL, NULL);
    printf("vmpoke: PTRACE_ATTACH = %ld\n", rc);
    if (rc == 0) {
        int st;
        if (waitpid(pid, &st, 0) < 0)
            perror("vmpoke: waitpid(attach)");
        errno = 0;
        rc = sys_ptrace(PT_POKEDATA, pid,
                        (void *)(caddr + offsetof(struct target_blob, poked)),
                        (void *)POKE_WORD);
        printf("vmpoke: PTRACE_POKEDATA(0x%lx <- 0x%lx) = %ld\n",
               caddr + offsetof(struct target_blob, poked), POKE_WORD, rc);
        rc = sys_ptrace(PT_DETACH, pid, NULL, NULL);
        printf("vmpoke: PTRACE_DETACH = %ld\n", rc);
    } else {
        fprintf(stderr, "vmpoke: ATTACH rc=%ld errno=%d (%s)\n", rc, errno,
                strerror(errno));
    }

    /* release child and collect verdict */
    if (write(done_pipe[1], "D", 1) != 1) {
        perror("vmpoke: done write");
        return 1;
    }
    close(done_pipe[1]);
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        perror("vmpoke: waitpid(exit)");
        return 1;
    }
    printf("vmpoke: child exit=%d\n", WEXITSTATUS(st));
    printf("vmpoke: now check kmsg, e.g.  dmesg | grep -E 'syscall=(%d|%d)' "
           "with comm=\"vmpoke\"\n", NR_PROCESS_VM_WR, NR_PTRACE);
    return WEXITSTATUS(st) == 0 ? 0 : 2;
}
