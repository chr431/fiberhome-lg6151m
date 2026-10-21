#include <stdio.h>
#include <unistd.h>
extern unsigned long __p0_hits;
extern const char *__p0_first;
extern unsigned long __p0_first_words[4];
static void w(const char *s, unsigned long n)
{ while (n) { ssize_t r = write(2, s, n); if (r <= 0) return; s += r; n -= (unsigned long)r; } }
static void wh(unsigned long v)
{ static const char h[] = "0123456789abcdef"; char t[24]; int k = 0;
  if (!v) { w("0", 1); return; } do { t[k++] = h[v & 15]; v >>= 4; } while (v); while (k) w(&t[--k], 1); }
int main(int argc, char **argv)
{
	static char b[24];
	unsigned long i, n = 300000000UL, acc = 0;
	if (argc > 1) { n = 0; for (const char *p = argv[1]; *p >= '0' && *p <= '9'; p++) n = n*10 + (unsigned long)(*p - '0'); }
	for (i = 0; i < n; i++) { snprintf(b, sizeof b, "%ld", (long)i); acc += (unsigned char)b[0]; }
	w("hits=", 5); wh(__p0_hits);
	w(" first=", 7); if (__p0_first) { for (const char *p = __p0_first; *p; p++) w(p, 1); } else w("-", 1);
	w(" w0=", 4); wh(__p0_first_words[0]);
	w(" w1=", 4); wh(__p0_first_words[1]);
	w(" w2=", 4); wh(__p0_first_words[2]);
	w(" w3=", 4); wh(__p0_first_words[3]);
	w("\n", 1);
	return (int)(acc & 1);
}
