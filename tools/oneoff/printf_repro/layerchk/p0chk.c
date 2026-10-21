#include <unistd.h>
#include <fcntl.h>
#include "p0chk.h"

unsigned long g_chk_n;

static void wstr(int fd, const char *s, unsigned long n)
{ while (n) { ssize_t r = write(fd, s, n); if (r <= 0) return; s += r; n -= (unsigned long)r; } }
static void wh(int fd, unsigned long v)
{ static const char h[] = "0123456789abcdef"; char t[20]; int k = 0;
  do { t[k++] = h[v & 15]; v >>= 4; } while (v); wstr(fd, "0x", 2); while (k) wstr(fd, &t[--k], 1); }
static void wb(int fd, unsigned v)
{ static const char h[] = "0123456789abcdef"; char t[2];
  t[0] = h[(v >> 4) & 15]; t[1] = h[v & 15]; wstr(fd, t, 2); }

void p0fail(const char *tag, const void *obj, unsigned long stack,
    unsigned long grtop, int groffs, unsigned long n)
{
	unsigned long sp, fp;
	__asm__ __volatile__("mov %0, sp" : "=r"(sp));
	__asm__ __volatile__("mov %0, x29" : "=r"(fp));
	int fd = open("/data/p0/layer.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
	int fs[2]; fs[0] = 2; fs[1] = fd;
	unsigned long base = ((unsigned long)obj - 0x80) & ~15UL;
	for (int i = 0; i < 2; i++) {
		int f = fs[i]; if (f < 0) continue;
		wstr(f, "FAIL tag=", 9); wstr(f, tag, __builtin_strlen(tag));
		wstr(f, " n=", 3); wh(f, n);
		wstr(f, " obj=", 5); wh(f, (unsigned long)obj);
		wstr(f, " stack=", 7); wh(f, stack);
		wstr(f, " gr_top=", 8); wh(f, grtop);
		wstr(f, " gr_offs=", 9); wh(f, (unsigned long)(long)groffs);
		wstr(f, " sp=", 4); wh(f, sp);
		wstr(f, " fp=", 4); wh(f, fp);
		wstr(f, "\n", 1);
		for (unsigned long a = base; a < base + 0x200; a += 32) {
			const unsigned char *p = (const unsigned char *)a;
			wh(f, a); wstr(f, ":", 1);
			for (int k = 0; k < 32; k++) { wstr(f, " ", 1); wb(f, p[k]); }
			wstr(f, "\n", 1);
		}
	}
	_exit(103);
}
