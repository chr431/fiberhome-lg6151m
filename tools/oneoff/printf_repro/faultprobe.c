/* faultprobe.c -- feasibility probe for a userspace self-scan defence.
 *
 * Question: at the moment of the crash, is the injection signature (SIGSEGV
 * 2.1: 16-byte block {small,0}, small == 0 or 0x2710..0x40000) present inside
 * the victim's OWN mapped memory?  If yes, a process can in principle detect
 * corruption before dereferencing it.  If no, the userspace-self-scan family
 * is ruled out the same way the page-holding family was (8.15).
 *
 * v2: scan bounds come from /proc/self/maps ([stack] and [heap]), never from a
 * blind window around SP -- v1 faulted inside its own handler and logged
 * nothing, which is exactly the kind of silent failure this project keeps
 * getting bitten by.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <ucontext.h>

#define LOGP "/tmp/faultprobe.log"

static unsigned long stk_lo, stk_hi, hp_lo, hp_hi;
static char out[4096];

static int put(char *b, int n, const char *s)
{ while (*s && n < 3900) b[n++] = *s++; return n; }

static int puthex(char *b, int n, unsigned long v)
{
	char t[20]; int k = 0;
	if (!v) t[k++] = '0';
	while (v) { t[k++] = "0123456789abcdef"[v & 15]; v >>= 4; }
	while (k) b[n++] = t[--k];
	return n;
}

static int is_sig(const unsigned int *p)
{
	unsigned int a = p[0], b = p[1];
	if (b != 0) return 0;
	/* v3: {0,0} is everywhere in a zeroed stack -- not a signature */
	if (a >= 0x2710u && a <= 0x40000u) return 1;
	return 0;
}

/* Parse one maps line: "lo-hi perms ... name" */
static void scan_maps(void)
{
	int fd = open("/proc/self/maps", O_RDONLY);
	char buf[8192]; ssize_t n; int i;
	if (fd < 0) return;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) return;
	buf[n] = 0;
	for (i = 0; i < n; ) {
		char *ln = buf + i, *e, *nm;
		unsigned long lo, hi;
		while (i < n && buf[i] != '\n') i++;
		if (i < n) buf[i++] = 0;
		lo = strtoul(ln, &e, 16);
		if (*e != '-') continue;
		hi = strtoul(e + 1, &e, 16);
		nm = strchr(ln, '/');
		if (!nm) nm = strstr(ln, "[");
		if (nm && strstr(nm, "[stack]")) { stk_lo = lo; stk_hi = hi; }
		if (nm && strstr(nm, "[heap]"))  { hp_lo = lo;  hp_hi = hi; }
	}
}

static int scan_region(unsigned long lo, unsigned long hi, int *hits, long *firstoff, unsigned int *firstval)
{
	unsigned long q;
	*hits = 0; *firstoff = -1; *firstval = 0;
	if (!lo || !hi || hi <= lo || (hi - lo) > (256UL * 1024 * 1024)) return 0;
	for (q = (lo + 15) & ~15UL; q + 16 <= hi; q += 16) {
		if (!is_sig((const unsigned int *)q)) continue;
		(*hits)++;
		if (*firstoff < 0) { *firstoff = (long)(q - lo); *firstval = *(unsigned int *)q; }
	}
	return 1;
}

static void on_segv(int sig, siginfo_t *si, void *uc)
{
	ucontext_t *c = (ucontext_t *)uc;
	unsigned long sp = (unsigned long)c->uc_mcontext.sp;
	unsigned long a = (unsigned long)si->si_addr;
	int sh = 0, hh = 0; long so = -1, ho = -1;
	unsigned int sv = 0, hv = 0;
	int n = 0, fd;

	scan_region(stk_lo, stk_hi, &sh, &so, &sv);
	scan_region(hp_lo, hp_hi, &hh, &ho, &hv);

	n = put(out, n, "FAULT sig=");   n = puthex(out, n, (unsigned long)sig);
	n = put(out, n, " addr=0x");     n = puthex(out, n, a);
	n = put(out, n, " sp=0x");       n = puthex(out, n, sp);
	n = put(out, n, " stk=[");       n = puthex(out, n, stk_lo);
	n = put(out, n, ",");            n = puthex(out, n, stk_hi);
	n = put(out, n, "] hits=");      n = puthex(out, n, (unsigned long)sh);
	n = put(out, n, " off=");        n = puthex(out, n, (unsigned long)(so < 0 ? 0 : so));
	n = put(out, n, " val=0x");      n = puthex(out, n, (unsigned long)sv);
	n = put(out, n, " heap_hits=");  n = puthex(out, n, (unsigned long)hh);
	n = put(out, n, " heap_val=0x"); n = puthex(out, n, (unsigned long)hv);
	n = put(out, n, "\n");

	fd = open(LOGP, O_CREAT | O_WRONLY | O_APPEND, 0600);
	if (fd >= 0) { ssize_t r = write(fd, out, n); (void)r; close(fd); }
	_exit(42);
}

int main(int argc, char **argv)
{
	static char sstack[65536];
	stack_t ss;
	struct sigaction sa;
	char b[24];
	unsigned long i, n = (argc > 1) ? strtoul(argv[1], 0, 10) : 60000000UL;

	scan_maps();
	ss.ss_sp = sstack; ss.ss_size = sizeof(sstack); ss.ss_flags = 0;
	sigaltstack(&ss, NULL);
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = on_segv;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);

	for (i = 0; i < n; i++)
		snprintf(b, sizeof b, "%ld", (long)i);
	return 0;
}
