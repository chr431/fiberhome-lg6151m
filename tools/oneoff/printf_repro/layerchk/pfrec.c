#include <stdio.h>
#include <unistd.h>
extern unsigned long __p0_va_guard_hits, __p0_va_last_ap, __p0_va_ap2, __p0_va_words[5], __p0_va_bad_off;
static void w(const char *s, unsigned long n)
{ while (n) { ssize_t r = write(2, s, n); if (r <= 0) return; s += r; n -= (unsigned long)r; } }
static void wh(const char *tag, unsigned long v)
{ static const char h[] = "0123456789abcdef"; char t[24]; int k = 0;
  while (*tag) { w(tag, 1); tag++; } w("=", 2 - 1);
  if (!v) { w("0", 1); } else { do { t[k++] = h[v & 15]; v >>= 4; } while (v); w("0x", 2); while (k) w(&t[--k], 1); }
  w("\n", 1); }
int main(int argc, char **argv)
{
	static char b[24];
	unsigned long i, n = 200000000UL, acc = 0;
	if (argc > 1) { n = 0; for (const char *p = argv[1]; *p >= '0' && *p <= '9'; p++) n = n*10 + (unsigned long)(*p - '0'); }
	for (i = 0; i < n; i++) { snprintf(b, sizeof b, "%ld", (long)i); acc += (unsigned char)b[0]; }
	wh("hits", __p0_va_guard_hits);
	wh("ap", __p0_va_last_ap);
	wh("ap2", __p0_va_ap2);
	wh("delta", __p0_va_bad_off);
	wh("w0", __p0_va_words[0]); wh("w1", __p0_va_words[1]);
	wh("w2", __p0_va_words[2]); wh("w3", __p0_va_words[3]);
	return (int)(acc & 1);
}
