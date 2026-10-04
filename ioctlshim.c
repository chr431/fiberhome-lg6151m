// LD_PRELOAD shim: dump /dev/fhdrv_net_dev ioctl ('N' nr 0..5) arg structs
// + follow embedded pointers (pon-style {cmd, in, inlen, out, outlen}).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>

static int (*real_ioctl)(int, unsigned long, void *);

__attribute__((constructor)) static void shim_init(void) {
    int fd = open("/tmp/ioctlshim.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dprintf(fd, "=== shim loaded pid=%d ===
", getpid()); close(fd); }
}
static int logfd = -1;

static void dump(const char *tag, void *p, int n) {
    if (!p || n <= 0) return;
    dprintf(logfd, "%s @%p:", tag, p);
    unsigned char *b = (unsigned char *)p;
    for (int i = 0; i < n; i++)
        dprintf(logfd, " %02x", b[i]);
    dprintf(logfd, "\n");
}

static void dump_ptrs(const char *tag, void *p, int n) {
    // dump qwords; if a qword looks like a userspace ptr, follow it
    unsigned long *q = (unsigned long *)p;
    for (int i = 0; i + 1 < n / 8; i += 2) {
        unsigned long v = q[i];
        unsigned long ln = q[i + 1];
        if (v > 0x10000 && v < 0x800000000000UL && ln > 0 && ln < 0x10000) {
            char t2[64];
            snprintf(t2, sizeof(t2), "%s.ptr[%d]+%lu", tag, i, ln > 128 ? 128UL : ln);
            dump(t2, (void *)v, ln > 128 ? 128 : (int)ln);
        }
    }
}

int ioctl(int fd, int request, ...)
{
    unsigned long cmd = (unsigned long)request;
    if (!real_ioctl)
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    if (logfd < 0)
        logfd = open("/tmp/ioctlshim.log", O_WRONLY | O_CREAT | O_APPEND, 0644);

    void *arg;
    va_list ap;
    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);

    unsigned char magic = (cmd >> 8) & 0xff;
    if (logfd >= 0 && magic == 'N' && ((cmd >> 30) & 3) == 3) {
        dprintf(logfd, "ioctl fd=%d cmd=%#lx\n", fd, cmd);
        dump("arg", arg, 64);
        dump_ptrs("arg", arg, 64);
    }
    return real_ioctl(fd, cmd, arg);
}
