/* p0probe2.c -- P0 in-process crash forensics (2026-10-22).
 *
 * p0probe showed: own variadic functions (no stdio) never crash in 5e7 calls,
 * every printf-family call does.  So the fault is inside musl stdio, and we
 * need the machine state at the fault without gdb (gdb changes timing and the
 * inferior then survives).
 *
 * This program installs a SIGSEGV handler that records, in plain text:
 *   mode, loop counter at fault, fault address, PC/SP/LR, x0..x30,
 *   the 32 bytes of code at PC, and a stack window.
 * One file per crash: /data/p0/dump.<pid>.txt  (text only: busybox has no
 * base64 on this rootfs, so binary is out).
 *
 * Modes (argv[1]), loop count argv[2] (default 2e8):
 *   a1 snprintf(b,24,"%ld",(long)i)      known reproducer
 *   a2 snprintf(b,24,"%ld",7L)           constant argument (data dependence)
 *   a3 snprintf(b,24,"abc")              no conversion at all
 *   a4 snprintf(g_b,24,"%ld",(long)i)    static buffer
 *   a5 sprintf(b,"%ld",(long)i)          unlimited width
 *   a6 snprintf(b,0,"%ld",(long)i)       zero size
 *   a7 snprintf x2 per iteration         rate check
 *   a8 snprintf + own variadic vsum      interleaved (who carries the state)
 */
#define _GNU_SOURCE
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <ucontext.h>
#include <fcntl.h>

static volatile unsigned long cur_i;
static volatile long gsink;
static char g_b[24];
static char g_mode[8];

static void wr(int fd, const char *s, size_t n)
{
	while (n) {
		ssize_t r = write(fd, s, n);
		if (r <= 0) return;
		s += r; n -= (size_t)r;
	}
}

static size_t put_hex(char *o, unsigned long v)
{
	static const char h[] = "0123456789abcdef";
	char t[20]; int k = 0, n = 0;
	if (!v) { o[n++] = '0'; return (size_t)n; }
	while (v) { t[k++] = h[v & 15]; v >>= 4; }
	o[n++] = '0'; o[n++] = 'x';
	while (k) o[n++] = t[--k];
	return (size_t)n;
}

/* fixed width, no prefix: two hex digits per byte, for the memory rows */
static void put_byte(char *o, unsigned v)
{
	static const char h[] = "0123456789abcdef";
	o[0] = h[(v >> 4) & 15];
	o[1] = h[v & 15];
}

static size_t put_dec(char *o, unsigned long v)
{
	char t[24]; int k = 0, n = 0;
	do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v);
	while (k) o[n++] = t[--k];
	return (size_t)n;
}

static FILE *g_null;

static __attribute__((noinline)) int my_vf(FILE *f, const char *fmt, ...)
{
	va_list ap; int r;
	va_start(ap, fmt);
	r = vfprintf(f, fmt, ap);
	va_end(ap);
	return r;
}

static __attribute__((noinline)) int my_vsn(char *s, size_t n, const char *fmt, ...)
{
	va_list ap; int r;
	va_start(ap, fmt);
	r = vsnprintf(s, n, fmt, ap);
	va_end(ap);
	return r;
}

static __attribute__((noinline)) long vsum(int n, ...)
{
	va_list ap; long s = 0; int i;
	va_start(ap, n);
	for (i = 0; i < n; i++) s += va_arg(ap, long);
	va_end(ap);
	return s;
}

static volatile int g_fd = -1;
static volatile unsigned long alt_lo, alt_hi;

static void put_line(const char *tag, unsigned long v)
{
	char b[48]; int n = 0;
	while (*tag) b[n++] = *tag++;
	b[n++] = '='; n += (int)put_hex(b + n, v); b[n++] = '\n';
	wr(g_fd, b, (size_t)n);
}

static void on_segv(int sig, siginfo_t *si, void *vp)
{
	ucontext_t *uc = (ucontext_t *)vp;
	unsigned long *r = uc->uc_mcontext.regs;
	char b[256]; int n, k;
	char path[48]; int pn = 0;
	static char code[32];
	const char *pfx = "/data/p0/dump.";
	unsigned long i;

	(void)sig;
	for (k = 0; pfx[k]; k++) path[pn++] = pfx[k];
	pn += (int)put_dec(path + pn, (unsigned long)getpid());
	g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (g_fd < 0) _exit(101);

	n = 0; while (g_mode[n]) n++;
	wr(g_fd, "mode=", 5); wr(g_fd, g_mode, (size_t)n); wr(g_fd, "\n", 1);
	put_line("cur_i", cur_i);
	put_line("si_addr", (unsigned long)si->si_addr);
	put_line("fault_address", (unsigned long)uc->uc_mcontext.fault_address);
	put_line("si_code", (unsigned long)si->si_code);
	put_line("alt_lo", alt_lo);
	put_line("alt_hi", alt_hi);
	put_line("sp_in_alt", ((unsigned long)uc->uc_mcontext.sp >= alt_lo &&
	    (unsigned long)uc->uc_mcontext.sp < alt_hi) ? 1 : 0);
	put_line("pc", (unsigned long)uc->uc_mcontext.pc);
	put_line("sp", (unsigned long)uc->uc_mcontext.sp);
	put_line("lr", (unsigned long)r[30]);
	for (k = 0; k < 30; k++) {
		char tag[8]; int m = 0;
		tag[m++] = 'x'; m += (int)put_dec(tag + m, (unsigned long)k); tag[m] = 0;
		put_line(tag, (unsigned long)r[k]);
	}
	/* 32 bytes of code at the faulting PC */
	memcpy(code, (const void *)(unsigned long)uc->uc_mcontext.pc, sizeof code);
	wr(g_fd, "code=", 5);
	for (k = 0; k < 32; k++) {
		static const char h[] = "0123456789abcdef";
		b[0] = h[(code[k] >> 4) & 15]; b[1] = h[code[k] & 15];
		wr(g_fd, b, 2);
	}
	wr(g_fd, "\n", 1);
	/* stack window: [sp-512, sp+0x3000) in 32-byte rows */
	{
		unsigned long base = ((unsigned long)uc->uc_mcontext.sp - 512) & ~15UL;
		unsigned long end = ((unsigned long)uc->uc_mcontext.sp + 0x3000);
		for (i = base; i < end; i += 32) {
			unsigned long a = i; const unsigned char *p = (const unsigned char *)i;
			n = 0; n += (int)put_hex(b + n, a); b[n++] = ':';
			for (k = 0; k < 32; k++) { put_byte(b + n, p[k]); n += 2; if (k != 31) b[n++] = ' '; }
			b[n++] = '\n';
			wr(g_fd, b, (size_t)n);
		}
	}
	/* every register that holds a stack-range pointer: 96 bytes at it */
	for (k = 0; k < 31; k++) {
		unsigned long p = (unsigned long)r[k];
		unsigned long base, end;
		if (p < 0x7f0000000000UL || p > 0x800000000000UL) continue;
		base = p & ~7UL; end = base + 96;
		if (base >= ((unsigned long)uc->uc_mcontext.sp - 512) &&
		    base < ((unsigned long)uc->uc_mcontext.sp + 0x3000)) continue;
		n = 0; b[n++] = 'R'; n += (int)put_dec(b + n, (unsigned long)k);
		b[n++] = ':'; n += (int)put_hex(b + n, base); b[n++] = '\n';
		wr(g_fd, b, (size_t)n);
		for (i = base; i < end; i += 32) {
			unsigned long a = i; const unsigned char *q = (const unsigned char *)i;
			n = 0; n += (int)put_hex(b + n, a); b[n++] = ':';
			for (int j = 0; j < 32; j++) { put_byte(b + n, q[j]); n += 2; if (j != 31) b[n++] = ' '; }
			b[n++] = '\n';
			wr(g_fd, b, (size_t)n);
		}
	}
	wr(g_fd, "end\n", 4);
	_exit(102);
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
	unsigned long i, N = argn(argc, argv, 200000000UL);
	const char *m = argc > 1 ? argv[1] : "a1";
	long acc = 0;
	struct sigaction sa;

	{
		int n = 0; while (m[n] && n < 7) { g_mode[n] = m[n]; n++; }
		g_mode[n] = 0;
	}
	{
		static char altbuf[131072];
		stack_t ss, rb;
		ss.ss_sp = altbuf; ss.ss_size = sizeof altbuf; ss.ss_flags = 0;
		alt_lo = (unsigned long)altbuf;
		alt_hi = alt_lo + sizeof altbuf;
		if (sigaltstack(&ss, &rb) == 0 && rb.ss_sp) { alt_lo = (unsigned long)rb.ss_sp; alt_hi = alt_lo + rb.ss_size; }
	}
	g_null = fopen("/dev/null", "w");
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = on_segv;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sigaction(SIGSEGV, &sa, 0);
	sigaction(SIGBUS, &sa, 0);

	for (i = 0; i < N; i++) {
		cur_i = i;
		if (!strcmp(m, "a1")) {
			snprintf(b, sizeof b, "%ld", (long)i);
			acc += b[0] + b[1];
		} else if (!strcmp(m, "a2")) {
			snprintf(b, sizeof b, "%ld", 7L);
			acc += b[0];
		} else if (!strcmp(m, "a3")) {
			snprintf(b, sizeof b, "abc");
			acc += b[0];
		} else if (!strcmp(m, "a4")) {
			snprintf(g_b, sizeof g_b, "%ld", (long)i);
			acc += g_b[0] + g_b[1];
		} else if (!strcmp(m, "a5")) {
			sprintf(b, "%ld", (long)i);
			acc += b[0] + b[1];
		} else if (!strcmp(m, "a6")) {
			acc += snprintf(b, 0, "%ld", (long)i);
		} else if (!strcmp(m, "a7")) {
			snprintf(b, sizeof b, "%ld", (long)i);
			snprintf(b, sizeof b, "%ld", (long)i + 1);
			acc += b[0] + b[1];
		} else if (!strcmp(m, "b1")) {
			acc += my_vf(g_null, "%ld", (long)i);
		} else if (!strcmp(m, "b2")) {
			acc += my_vsn(b, sizeof b, "%ld", (long)i);
		} else if (!strcmp(m, "a8")) {
			snprintf(b, sizeof b, "%ld", (long)i);
			acc += vsum(1, (long)i) + b[0] + b[1];
		} else {
			return 2;
		}
		gsink = acc;
	}
	{
		char t[32]; int n = 0;
		t[n++] = 'o'; t[n++] = 'k'; t[n++] = ' '; t[n++] = 'N'; t[n++] = '=';
		n += (int)put_dec(t + n, N); t[n++] = ' '; t[n++] = 'i'; t[n++] = '=';
		n += (int)put_dec(t + n, N); t[n++] = '\n';
		wr(2, t, (size_t)n);
	}
	return (int)(acc & 1);
}
