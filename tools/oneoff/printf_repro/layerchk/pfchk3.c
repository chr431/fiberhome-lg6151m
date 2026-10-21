/* pfchk3.c -- copy-free printf chain vs the real one (P0 bisect).
 * c1: own variadic wrapper -> explicit memcpy -> p0_vf_impl (printf_core)
 * c2: own variadic wrapper -> libc vfprintf            (control)
 * c3: libc snprintf                                    (control)
 */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include "p0chk.h"
#include "p0copy.h"

int p0_vf_impl(FILE *f, const char *fmt, const void *apwords);

static FILE *gnull;
static int g_baseline = 5;

static void hx(const char *tag, const unsigned long *w, int n)
{
	static const char h[] = "0123456789abcdef";
	char buf[160]; int m = 0;
	while (*tag) buf[m++] = *tag++;
	buf[m++] = ':';
	for (int i = 0; i < n; i++) {
		char t[20]; int k = 0; unsigned long v = w[i];
		buf[m++] = ' ';
		buf[m++] = '0'; buf[m++] = 'x';
		do { t[k++] = h[v & 15]; v >>= 4; } while (v);
		while (k) buf[m++] = t[--k];
	}
	buf[m++] = '\n';
	if (write(2, buf, (unsigned long)m) < 0) return;
}

static __attribute__((noinline)) int wrap_p0(FILE *f, const char *fmt, ...)
{
	va_list ap;
	unsigned long snap[4];
	int r;
	va_start(ap, fmt);
	p0_bytecopy(snap, &ap, sizeof snap);
	CHK("wrapper.own_va_list", snap);
	if (g_baseline > 0) { g_baseline--; hx("baseline.own", snap, 4); hx("baseline.source", (const unsigned long *)&ap, 4); }
	r = p0_vf_impl(f, fmt, &ap);
	va_end(ap);
	return r;
}

static __attribute__((noinline)) int wrap_libc(FILE *f, const char *fmt, ...)
{
	va_list ap; int r;
	va_start(ap, fmt);
	r = vfprintf(f, fmt, ap);
	va_end(ap);
	return r;
}

static void w(const char *s, unsigned long n)
{ while (n) { ssize_t r = write(2, s, n); if (r <= 0) return; s += r; n -= (unsigned long)r; } }

int main(int argc, char **argv)
{
	static char b[24];
	unsigned long i, n = 100000000UL;

	if (argc > 1) { n = 0; for (const char *p = argv[1]; *p >= '0' && *p <= '9'; p++) n = n*10 + (unsigned long)(*p - '0'); }
	gnull = fopen("/dev/null", "w");
	for (i = 0; i < n; i++) {
		if (argc > 2 && argv[2][0] == '2') { wrap_libc(gnull, "%ld", (long)i); }
		else if (argc > 2 && argv[2][0] == '3') { snprintf(b, sizeof b, "%ld", (long)i); }
		else { wrap_p0(gnull, "%ld", (long)i); }
	}
	w("survived ", 9);
	return 0;
}
