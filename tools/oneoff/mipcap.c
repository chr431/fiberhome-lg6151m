/* mipcap.c — oneoff 取证: LD_PRELOAD 记录目标进程在 /dev/ttyCMIPC* 上的 I/O 字节。
 * 用途: 抓 ql_ril_service 的 MIPC 报文(触发: mipc_cellular cells/getbands/endc/...)
 *       为 cells 直连迁移提供 msgid/TLV/帧格式证据。
 * 构建: zig cc -target aarch64-linux-musl -shared -fPIC -o mipcap.so <本文件> -ldl
 * 用法: LD_PRELOAD=/tmp/mipcap.so <target>; 结果 /tmp/mipcap.log
 * v2: musl 内部 open 不过 PLT(open 截不到) — fd 判别改为 read/write 时 readlink。
 * v3: constructor 自证标记(LOADED) + readv/writev/ioctl 兜底(线程采样证实 read 在用)。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <time.h>
#include <sys/uio.h>

static int (*r_open)(const char *, int, ...);
static int (*r_openat)(int, const char *, int, ...);
static ssize_t (*r_write)(int, const void *, size_t);
static ssize_t (*r_read)(int, void *, size_t);
static ssize_t (*r_readv)(int, const struct iovec *, int);
static ssize_t (*r_writev)(int, const struct iovec *, int);
static int (*r_ioctl)(int, unsigned long, void *);
static ssize_t (*r_readlink)(const char *, char *, size_t);

static int logfd = -1;
static int busy = 0;                 /* 写日志期间的递归守卫 */
static unsigned char is_mipc[256];   /* fd -> 0=未查 1=ttyCMIPC 2=非 */

static void resolve(void)
{
    if (r_open) return;
    r_open   = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    r_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    r_write  = (ssize_t (*)(int, const void *, size_t))dlsym(RTLD_NEXT, "write");
    r_read   = (ssize_t (*)(int, void *, size_t))dlsym(RTLD_NEXT, "read");
    r_readv  = (ssize_t (*)(int, const struct iovec *, int))dlsym(RTLD_NEXT, "readv");
    r_writev = (ssize_t (*)(int, const struct iovec *, int))dlsym(RTLD_NEXT, "writev");
    r_ioctl  = (int (*)(int, unsigned long, void *))dlsym(RTLD_NEXT, "ioctl");
    r_readlink = (ssize_t (*)(const char *, char *, size_t))dlsym(RTLD_NEXT, "readlink");
}

__attribute__((constructor)) static void boot(void)
{
    resolve();
    busy = 1;
    if (logfd < 0) logfd = r_open("/tmp/mipcap.log", O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (logfd >= 0) {
        const char m0[] = "LOADED\n";
        r_write(logfd, m0, sizeof m0 - 1);
    }
    busy = 0;
}

static int mipc_fd(int fd)
{
    if (fd < 0 || fd >= 256) return 0;
    if (is_mipc[fd] == 0) {
        char lnk[64], tgt[128];
        snprintf(lnk, sizeof lnk, "/proc/self/fd/%d", fd);
        int n = (int)r_readlink(lnk, tgt, sizeof tgt - 1);
        if (n <= 0) return 0;
        tgt[n] = 0;
        is_mipc[fd] = strstr(tgt, "ttyCMIPC") ? 1 : 2;
    }
    return is_mipc[fd] == 1;
}

static void emit(const char *tag, int fd, const unsigned char *b, ssize_t n)
{
    if (busy) return;
    busy = 1;
    if (logfd < 0) {
        int fdlog = r_open("/tmp/mipcap.log", O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fdlog < 0) { busy = 0; return; }
        logfd = fdlog;
    }
    char head[128];
    int hl = snprintf(head, sizeof head, "[%ld] %s fd=%d n=%zd ",
                      (long)time(0), tag, fd, n);
    r_write(logfd, head, hl);
    for (ssize_t i = 0; i < n && i < 4096; i++) {
        char hx[3];
        hx[0] = "0123456789abcdef"[b[i] >> 4];
        hx[1] = "0123456789abcdef"[b[i] & 15];
        hx[2] = 0;
        r_write(logfd, hx, 2);
    }
    r_write(logfd, "\n", 1);
    busy = 0;
}

int open(const char *path, int flags, ...)
{
    resolve();
    mode_t m = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); m = va_arg(ap, int); va_end(ap);
    }
    int fd = r_open(path, flags, m);
    if (!busy && path && strstr(path, "ttyCMIPC") && fd >= 0 && fd < 256) {
        is_mipc[fd] = 1;
        emit("OPEN", fd, (const unsigned char *)path, (ssize_t)strlen(path));
    }
    return fd;
}

int openat(int dirfd, const char *path, int flags, ...)
{
    resolve();
    mode_t m = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); m = va_arg(ap, int); va_end(ap);
    }
    int fd = r_openat(dirfd, path, flags, m);
    if (!busy && path && strstr(path, "ttyCMIPC") && fd >= 0 && fd < 256) {
        is_mipc[fd] = 1;
        emit("OPENAT", fd, (const unsigned char *)path, (ssize_t)strlen(path));
    }
    return fd;
}

ssize_t write(int fd, const void *buf, size_t n)
{
    resolve();
    ssize_t r = r_write(fd, buf, n);
    if (!busy && mipc_fd(fd) && n)
        emit("W", fd, buf, r > 0 ? r : (ssize_t)n);
    return r;
}

ssize_t read(int fd, void *buf, size_t n)
{
    resolve();
    ssize_t r = r_read(fd, buf, n);
    if (!busy && mipc_fd(fd) && r > 0)
        emit("R", fd, buf, r);
    return r;
}

ssize_t readv(int fd, const struct iovec *iov, int cnt)
{
    resolve();
    ssize_t r = r_readv(fd, iov, cnt);
    if (!busy && r > 0 && mipc_fd(fd)) {
        for (int i = 0; i < cnt; i++)
            if (iov[i].iov_len)
                emit("RV", fd, iov[i].iov_base, (ssize_t)iov[i].iov_len);
    }
    return r;
}

ssize_t writev(int fd, const struct iovec *iov, int cnt)
{
    resolve();
    ssize_t r = r_writev(fd, iov, cnt);
    if (!busy && mipc_fd(fd)) {
        for (int i = 0; i < cnt; i++)
            if (iov[i].iov_len)
                emit("WV", fd, iov[i].iov_base, (ssize_t)iov[i].iov_len);
    }
    return r;
}

int ioctl(int fd, unsigned long req, void *arg)
{
    resolve();
    int r = r_ioctl(fd, req, arg);
    if (!busy && mipc_fd(fd))
        emit("IO", fd, (const unsigned char *)&req, sizeof req);
    return r;
}
