// rectest.c -- inject the 32B record into this process's own va_list; with nerepair it survives.
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
static int f(const char *fmt, ...) {
    va_list ap; char buf[128]; int n;
    va_start(ap, fmt);
    unsigned long *p = (unsigned long *)(void *)&ap;
    p[0] = 0x14d83; p[1] = 0; p[2] = 0x0109a8c000000641UL; p[3] = 0;
    n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    printf("SURVIVED n=%d buf=%s\n", n, buf);
    return 0;
}
int main(void) { f("%d %d %d", 1, 2, 3); printf("DONE\n"); return 0; }
