#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
int main(void) {
    unsigned char *p = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    memcpy(p, "PATRACE_MAGIC16", 16);
    printf("%d %lx\n", (int)getpid(), (unsigned long)p);
    fflush(stdout);
    sleep(120);
    return 0;
}
