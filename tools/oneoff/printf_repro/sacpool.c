/* sacpool.c -- sacrificial page pool (SIGSEGV Phase 2 new stack, 2026-10-26).
 *
 * Mechanism it targets (docs/SIGSEGV_ANALYSIS.md 1 + 8.6):
 *   The MD firmware keeps a private STALE list of ~400 fixed PAs and keeps
 *   writing 16/32-byte ring records into them via DPMAIF RX DMA.  Those pages
 *   are ex-anon zero pages sitting on the MOVABLE free lists; once the kernel
 *   hands one to userland, the process gets corrupted memory and SIGSEGVs.
 *   The list does not grow -- it is a fixed population churning at ~1 page/s.
 *
 * Idea: hold a large pool of MOVABLE anonymous pages and never dereference
 *   their content.  Any stale page that gets freed and re-allocated into this
 *   pool is removed from circulation permanently, and the MD's writes land in
 *   memory nobody reads.  Because anon pages are exactly the migratetype the
 *   stale pages live in, the pool competes for the same page class.
 *
 * Safety: pure userspace.  No kernel module, no syscall interception, nothing
 *   that can wedge the box.  The only cost is resident memory, which is why
 *   the size is a parameter -- measure the dose-response curve before picking.
 *
 * Usage: sacpool <MB> [seconds]
 *   Allocates MB megabytes, touches every page (forcing real allocation),
 *   then holds.  Re-touches every 30 s so reclaim pressure cannot take them
 *   back.  Runs until killed, or for <seconds> if given.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>

#define PAGE 4096UL

int main(int argc, char **argv)
{
	long mb = (argc > 1) ? atol(argv[1]) : 128;
	long secs = (argc > 2) ? atol(argv[2]) : 0;   /* 0 = forever */
	size_t sz = (size_t)mb * 1024UL * 1024UL;
	unsigned long off;
	long elapsed = 0;
	char *p;

	if (mb <= 0 || mb > 1024) {
		fprintf(stderr, "sacpool: MB out of range (1..1024)\n");
		return 2;
	}
	p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		perror("sacpool: mmap");
		return 1;
	}
	/* Touch every page: anon faults allocate MOVABLE pages, the same class
	 * the MD's stale list lives in.  Write-only touch -- we never read. */
	for (off = 0; off < sz; off += PAGE)
		p[off] = 1;
	fprintf(stderr, "sacpool: holding %ld MB (%lu pages)\n", mb, sz / PAGE);

	for (;;) {
		sleep(30);
		elapsed += 30;
		for (off = 0; off < sz; off += PAGE)
			p[off] = 1;          /* keep them active, never read them */
		if (secs > 0 && elapsed >= secs)
			break;
	}
	munmap(p, sz);
	return 0;
}
