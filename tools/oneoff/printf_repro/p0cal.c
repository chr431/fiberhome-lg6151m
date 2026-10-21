/* p0cal.c -- instrument calibration for the SIGSEGV dumper (2026-10-22).
 *
 * The p0probe3 dumps contradict themselves (x19 != [sp+8], [x2] != si_addr).
 * Never trust a forensic instrument that has not been calibrated: this program
 * provokes a fault with a fully known register and stack state, so the dump
 * can be checked field by field.
 *
 * Known state at the fault:
 *   x10 = SENT0, x11 = SENT1, x12 = FAULTADDR, x13 = SENT2
 *   the faulting instruction is 'ldr x13, [x12]'
 *   a 64-byte stack local 'pattern' holds SENT0..SENT0^3
 * The handler then records mode "cal", registers, PC, and a stack window,
 * and also reports whether the signal frame landed on the alt stack.
 */
#define _GNU_SOURCE
#include <stddef.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <ucontext.h>
#include <fcntl.h>

#define FAULTADDR 0x3000UL
static char altbuf[65536];
static volatile int g_fd = -1;
static volatile unsigned long alt_lo, alt_hi;

static void wr(int fd, const char *s, size_t n)
{
	while (n) { ssize_t r = write(fd, s, n); if (r <= 0) return; s += r; n -= (size_t)r; }
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
static size_t put_dec(char *o, unsigned long v)
{
	char t[24]; int k = 0, n = 0;
	do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v);
	while (k) o[n++] = t[--k];
	return (size_t)n;
}
static void line(const char *tag, unsigned long v)
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
	unsigned long sp = (unsigned long)uc->uc_mcontext.sp;
	char b[96]; int n, k; unsigned long i;
	(void)sig;
	g_fd = open("/data/p0/cal.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (g_fd < 0) _exit(101);
	wr(g_fd, "mode=cal\n", 9);
	line("si_addr", (unsigned long)si->si_addr);
	line("fault_address", (unsigned long)uc->uc_mcontext.fault_address);
	line("pc", (unsigned long)uc->uc_mcontext.pc);
	line("sp", sp);
	line("alt_lo", alt_lo);
	line("alt_hi", alt_hi);
	line("sp_in_alt", (sp >= alt_lo && sp < alt_hi) ? 1 : 0);
	for (k = 0; k < 30; k++) {
		char tag[8]; int m = 0;
		tag[m++] = 'x'; m += (int)put_dec(tag + m, (unsigned long)k);
		tag[m] = 0;
		line(tag, (unsigned long)r[k]);
	}
	{
		unsigned long base = (sp - 512) & ~15UL, end = sp + 1024;
		for (i = base; i < end; i += 32) {
			const unsigned char *p = (const unsigned char *)i;
			n = 0; n += (int)put_hex(b + n, i); b[n++] = ':';
			for (k = 0; k < 32; k++) { n += (int)put_hex(b + n, p[k]); b[n++] = ' '; }
			b[n++] = '\n';
			wr(g_fd, b, (size_t)n);
		}
	}
	wr(g_fd, "end\n", 4);
	_exit(102);
}

int main(void)
{
	struct sigaction sa;
	stack_t ss;
	long sents[8];
	volatile long pattern[8];
	int i;
	static const unsigned long S0 = 0x1111111111111111UL, S1 = 0x2222222222222222UL,
	    S2 = 0x3333333333333333UL;

	alt_lo = (unsigned long)altbuf; alt_hi = (unsigned long)altbuf + sizeof altbuf;
	ss.ss_sp = altbuf; ss.ss_size = sizeof altbuf; ss.ss_flags = 0;
	if (sigaltstack(&ss, 0)) { wr(2, "sigaltstack failed\n", 19); return 3; }
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = on_segv;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sigaction(SIGSEGV, &sa, 0);

	for (i = 0; i < 8; i++) { sents[i] = (long)S0; pattern[i] = (long)(S2 + (unsigned long)i); }

	__asm__ __volatile__(
	    "ldr x10, [%0]\n\t"
	    "ldr x11, [%0, #8]\n\t"
	    "mov x12, #0x3000\n\t"
	    "ldr x13, [x12]\n\t"
	    :
	    : "r"(sents)
	    : "x10", "x11", "x12", "x13", "memory");
	(void)pattern;
	return (int)(S1 & 1);
}
