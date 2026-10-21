#include <unistd.h>
#include <fcntl.h>
#include "chk2.h"
unsigned long g_src[6];
static void ws(int fd, const char *s, unsigned long n)
{ while (n) { ssize_t r = write(fd, s, n); if (r <= 0) return; s += r; n -= (unsigned long)r; } }
static void wh(int fd, unsigned long v)
{ static const char h[] = "0123456789abcdef"; char t[20]; int k = 0;
  do { t[k++] = h[v & 15]; v >>= 4; } while (v); ws(fd, "0x", 2); while (k) ws(fd, &t[--k], 1); }
void p0rpt(const char *tag, unsigned long a, unsigned long b, unsigned long c,
    unsigned long d, unsigned long e)
{
	int fd = open("/data/p0/handoff.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
	int fs[2]; fs[0] = 2; fs[1] = fd;
	for (int i = 0; i < 2; i++) {
		int f = fs[i]; if (f < 0) continue;
		ws(f, tag, __builtin_strlen(tag)); ws(f, ":", 1);
		wh(f, a); ws(f, " ", 1); wh(f, b); ws(f, " ", 1);
		wh(f, c); ws(f, " ", 1); wh(f, d); ws(f, " ", 1); wh(f, e);
		ws(f, "\n", 1);
	}
	_exit(104);
}
