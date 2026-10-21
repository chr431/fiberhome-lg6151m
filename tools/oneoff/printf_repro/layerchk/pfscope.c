/* pfscope.c -- is the va_list corruption printf-specific or general?
 *
 * Same guard as the hardened vfprintf (upper 16 bytes of the AAPCS64
 * va_list must describe real memory), applied to
 *   mode p: snprintf("%ld")            -- known to corrupt
 *   mode v: own variadic vsum(1, i)    -- no libc stdio at all
 * Counts bad va_lists instead of dying, so the two rates are comparable.
 * Argv: <mode> <iterations>
 */
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>

struct va4 { unsigned long stack, gr_top, vr_top; int gr_offs, vr_offs; };

static unsigned long g_bad, g_calls;

static void w(const char *s, unsigned long n)
{ while (n) { ssize_t r = write(2, s, n); if (r <= 0) return; s += r; n -= (unsigned long)r; } }
static void wn(unsigned long v)
{ char t[24]; int k = 0; if (!v) { w("0", 1); return; } do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); while (k) w(&t[--k], 1); }

static int bad(const struct va4 *a)
{
	return !(a->stack >= 0x1000UL && a->gr_top >= 0x1000UL &&
	    a->vr_top >= 0x1000UL && a->gr_offs < 0 && a->vr_offs < 0);
}

static __attribute__((noinline)) long vsum1(int n, ...)
{
	va_list ap;
	long s;
	va_start(ap, n);
	g_calls++;
	if (bad((const struct va4 *)&ap)) g_bad++;
	s = va_arg(ap, long);
	va_end(ap);
	return s + n;
}

int main(int argc, char **argv)
{
	static char b[24];
	unsigned long i, n = 200000000UL, acc = 0;
	char mode = argc > 1 ? argv[1][0] : 'p';

	if (argc > 2) { n = 0; for (const char *p = argv[2]; *p >= '0' && *p <= '9'; p++) n = n*10 + (unsigned long)(*p - '0'); }
	for (i = 0; i < n; i++) {
		if (mode == 'v') acc += (unsigned long)vsum1(1, (long)i);
		else { snprintf(b, sizeof b, "%ld", (long)i); acc += (unsigned char)b[0]; }
	}
	w(mode == 'v' ? "vsum " : "snprintf ", (unsigned long)(mode == 'v' ? 5 : 9));
	w("calls=", 6); wn(mode == 'v' ? g_calls : n);
	w(" bad=", 5); wn(g_bad);
	w("\n", 1);
	return (int)(acc & 1);
}
