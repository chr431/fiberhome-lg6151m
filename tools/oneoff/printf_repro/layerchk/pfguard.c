/* pfguard.c -- a1 loop for the hardened vs stock vfprintf A/B.
 * usage: pfguard <iterations>   (mode "g" linked hardened, "c" stock control)
 */
#include <stdio.h>
#include <unistd.h>

extern unsigned long __p0_va_guard_hits __attribute__((weak));

static void w(const char *s, unsigned long n)
{ while (n) { ssize_t r = write(2, s, n); if (r <= 0) return; s += r; n -= (unsigned long)r; } }
static void wn(unsigned long v)
{ char t[24]; int k = 0; if (!v) { w("0", 1); return; } do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); while (k) w(&t[--k], 1); }

int main(int argc, char **argv)
{
	static char b[24];
	unsigned long i, n = 200000000UL, acc = 0;

	if (argc > 1) { n = 0; for (const char *p = argv[1]; *p >= '0' && *p <= '9'; p++) n = n*10 + (unsigned long)(*p - '0'); }
	for (i = 0; i < n; i++) {
		snprintf(b, sizeof b, "%ld", (long)i);
		acc += (unsigned char)b[0];
	}
	w("survived calls=", 16); wn(n);
	w(" guard_hits=", 12); wn(&__p0_va_guard_hits ? __p0_va_guard_hits : 0);
	w("\n", 1);
	return (int)(acc & 1);
}
