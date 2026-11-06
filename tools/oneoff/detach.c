#define _GNU_SOURCE
#include <unistd.h>
#include <fcntl.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    pid_t p = fork();
    if (p < 0) return 1;
    if (p > 0) return 0;
    setsid();
    p = fork();
    if (p < 0) _exit(1);
    if (p > 0) _exit(0);
    int fd = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); }
    int z = open("/dev/null", O_RDONLY);
    if (z >= 0) dup2(z, 0);
    execvp(argv[2], &argv[2]);
    _exit(127);
}
