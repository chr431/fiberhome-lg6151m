/* p0probe.c -- P0 fault-localisation matrix (2026-10-22).
 *
 * One binary, several modes, selected by argv[1]; optional argv[2] = loop
 * count (default 5e7).  Everything hot is printf-free: progress and results
 * go out through raw write(2), so a mode that crashes isolates the fault to
 * the operation under test, not to the reporting.
 *
 * Modes
 *   r1  snprintf(b,24,"%ld",i)                  -- the known reproducer
 *   r2  snprintf(b,96,"%ld "*9, ...)            -- forces stack-passed args
 *   r3  own variadic vsum(1, i)                 -- NO libc stdio at all
 *   r3b own variadic vsum(9, ...)               -- same, stack-passed args
 *   r4  own variadic taking a pointer, deref    -- proves corrupt va_arg faults
 *   r5  control: plain call returning an int    -- background rate
 *   r6  vsnprintf through an own va_list wrapper
 *   r7  snprintf(b,24,"%s", buf)                -- no integer conversion
 *   r8  snprintf(b,24,"%e", (double)i)          -- FP path (__vr_top)
 *   r9  snprintf(b,24,"%ld",i) under a sigaltstack+handler that counts
 *       SIGSEGV instead of dying (to see if we can survive and keep going)
 */
#define _GNU_SOURCE
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>

static void wr(const char *s, size_t n)
{
	while (n) {
		ssize_t r = write(2, s, n);
		if (r <= 0) return;
		s += r; n -= (size_t)r;
	}
}

static void wnum(unsigned long v)
{
	char b[24]; int n = 0, k = 0; char t[24];
	do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v);
	while (k) b[n++] = t[--k];
	b[n++] = '\n';
	wr(b, (size_t)n);
}

static volatile long gsink;

static __attribute__((noinline)) long plain_call(long x) { return x + 1; }

static __attribute__((noinline)) long vsum(int n, ...)
{
	va_list ap;
	long s = 0;
	int i;
	va_start(ap, n);
	for (i = 0; i < n; i++) s += va_arg(ap, long);
	va_end(ap);
	return s;
}

static __attribute__((noinline)) long vderef(int n, ...)
{
	va_list ap;
	long s = 0;
	int i;
	va_start(ap, n);
	for (i = 0; i < n; i++) s += *(const long *)va_arg(ap, void *);
	va_end(ap);
	return s;
}

static __attribute__((noinline)) int my_vsnprintf(char *b, size_t n, const char *f, ...)
{
	va_list ap;
	int r;
	va_start(ap, f);
	r = vsnprintf(b, n, f, ap);
	va_end(ap);
	return r;
}

static void on_segv(int sig, siginfo_t *si, void *ctx)
{
	static unsigned long hits;
	char m[64]; int n = 0;
	(void)ctx;
	hits++;
	wr("SIGSEGV hit=", 12);
	wnum(hits);
	wr("addr=", 5);
	wnum((unsigned long)si->si_addr);
	(void)m; (void)n;
	/* Do not return: the instruction would re-fault in a loop. */
	_exit(100);
}

static unsigned long argn(int argc, char **argv, unsigned long def)
{
	unsigned long v = 0; const char *p;
	if (argc < 3) return def;
	for (p = argv[2]; *p >= '0' && *p <= '9'; p++) v = v * 10 + (unsigned long)(*p - '0');
	return v ? v : def;
}

int main(int argc, char **argv)
{
	char b[128];
	unsigned long i, N = argn(argc, argv, 50000000UL);
	const char *m = argc > 1 ? argv[1] : "r1";
	long acc = 0, v = 0x5a5a5a5a;
	static struct sigaction sa;

	if (!strcmp(m, "r9")) {
		sa.sa_sigaction = on_segv;
		sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
		sigaction(SIGSEGV, &sa, 0);
	}

	wr("start ", 6); wr(m, strlen(m)); wr(" N=", 3); wnum(N);

	for (i = 0; i < N; i++) {
		if (!strcmp(m, "r1") || !strcmp(m, "r9")) {
			snprintf(b, sizeof b, "%ld", (long)i);
			acc += b[0] + b[1];
		} else if (!strcmp(m, "r2")) {
			snprintf(b, sizeof b, "%ld %ld %ld %ld %ld %ld %ld %ld %ld",
			    (long)i, (long)i, (long)i, (long)i, (long)i,
			    (long)i, (long)i, (long)i, (long)i);
			acc += b[0] + b[8] + b[20];
		} else if (!strcmp(m, "r3")) {
			acc += vsum(1, (long)i);
		} else if (!strcmp(m, "r3b")) {
			acc += vsum(9, (long)i, (long)i, (long)i, (long)i, (long)i,
			    (long)i, (long)i, (long)i, (long)i);
		} else if (!strcmp(m, "r4")) {
			acc += vderef(2, &v, &v);
		} else if (!strcmp(m, "r5")) {
			acc += plain_call((long)i);
		} else if (!strcmp(m, "r6")) {
			acc += my_vsnprintf(b, sizeof b, "%ld", (long)i);
		} else if (!strcmp(m, "r7")) {
			strcpy(b, "0123456789abcdef");
			acc += my_vsnprintf(b, sizeof b, "%s", b);
		} else if (!strcmp(m, "r8")) {
			snprintf(b, sizeof b, "%e", (double)i);
			acc += b[0];
		} else {
			wr("unknown mode\n", 13);
			return 2;
		}
		gsink = acc;
	}
	wr("survived ", 9); wr(m, strlen(m)); wr(" acc=", 5);
	wnum((unsigned long)acc);
	return 0;
}
