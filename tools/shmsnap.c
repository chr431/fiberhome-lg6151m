/* shmsnap.c v1.0 -- cfgmgr 配置树共享内存快照 (save/load 原始16MB)
 * 树存 SysV shm key=0x7539 (16MB, attach 0x58800000), 每次开机由 cfg_tool
 * 以出厂档案重建 — 快照在重建后整体覆盖即恢复全部树状态(含锁频段/锁小区)。
 * 用法: shmsnap save <file>   内存 -> 文件 (gzip 由调用方处理)
 *       shmsnap load <file>   文件 -> 内存 (需段已存在, 即 cfg_tool 之后)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#define SHM_KEY 0x7539
#define SHM_SIZE 0x1000000

int main(int argc, char **argv)
{
    if (argc != 3 || (strcmp(argv[1], "save") && strcmp(argv[1], "load"))) {
        fprintf(stderr, "usage: shmsnap save|load <file>\n");
        return 2;
    }
    int id = shmget(SHM_KEY, SHM_SIZE, 0666);
    if (id < 0) { fprintf(stderr, "shmget: %s (cfg_tool ran?)\n", strerror(errno)); return 1; }
    void *p = shmat(id, 0, 0);
    if (p == (void*)-1) { fprintf(stderr, "shmat: %s\n", strerror(errno)); return 1; }

    if (!strcmp(argv[1], "save")) {
        int f = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (f < 0) { fprintf(stderr, "open: %s\n", strerror(errno)); return 1; }
        ssize_t n = write(f, p, SHM_SIZE);
        close(f);
        printf("saved %zd bytes\n", n);
        return n == SHM_SIZE ? 0 : 1;
    }
    /* load */
    int f = open(argv[2], O_RDONLY);
    if (f < 0) { fprintf(stderr, "open: %s\n", strerror(errno)); return 1; }
    ssize_t n = read(f, p, SHM_SIZE);
    close(f);
    printf("loaded %zd bytes\n", n);
    return (n == SHM_SIZE) ? 0 : 1;
}
