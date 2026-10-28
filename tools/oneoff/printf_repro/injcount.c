/* injcount.c -- direct injection counter (SIGSEGV Phase 2, 2026-10-26).
 *
 * Why this exists: the TTC metric (pfcanary time-to-crash) is a RACE -- it
 * depends on the canary's stack page happening to be a stale page, which in
 * turn depends on what every other process is allocating.  On a live device
 * with ~40 process spawns/s that noise swamps any effect (measured: baseline
 * blocks swing 2.7 sigma within minutes, see SIGSEGV_ANALYSIS 8.14).
 *
 * This tool measures the thing itself: poison a block of pages with a known
 * pattern, wait, then count how many pages an EXTERNAL writer modified.
 * External DMA writes bypass the MMU, so our private anon pages are only ever
 * touched by the MD's stale-list writes.  Result is a count, not a race.
 *
 * Assumes a QUIESCED device (daemons stopped, modem stack still up) -- under
 * memory pressure a reclaimed page would refault as zeros and look "modified".
 *
 * Usage: injcount <MB> <seconds>
 *   prints: "injcount pages=<N> modified=<M> mb=<MB> secs=<S>"
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>

#define PAGE 4096UL
#define PAT  0xA5A5A5A5u

int main(int argc, char **argv)
{
	long mb = (argc > 1) ? atol(argv[1]) : 256;
	long secs = (argc > 2) ? atol(argv[2]) : 60;
	size_t sz = (size_t)mb * 1024UL * 1024UL;
	unsigned long npages = sz / PAGE, i, j, modified = 0;
	unsigned int *p;
	volatile unsigned int *vp;

	if (mb <= 0 || mb > 768) {
		fprintf(stderr, "injcount: MB out of range (1..768)\n");
		return 2;
	}
	p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		perror("injcount: mmap");
		return 1;
	}
	/* Poison every word of every page. */
	for (i = 0; i < npages; i++) {
		unsigned int *pg = p + (i * PAGE / sizeof(unsigned int));
		for (j = 0; j < PAGE / sizeof(unsigned int); j++)
			pg[j] = PAT;
	}
	fprintf(stderr, "injcount: poisoned %lu pages (%ld MB), waiting %ld s\n",
		npages, mb, secs);
	sleep(secs);

	/* Any word that is not PAT was written by someone other than us. */
	vp = (volatile unsigned int *)p;
	for (i = 0; i < npages; i++) {
		unsigned long base = i * (PAGE / sizeof(unsigned int));
		int hit = 0;
		for (j = 0; j < PAGE / sizeof(unsigned int); j++) {
			if (vp[base + j] != PAT) { hit = 1; break; }
		}
		if (hit)
			modified++;
	}
	printf("injcount pages=%lu modified=%lu mb=%ld secs=%ld\n",
	       npages, modified, mb, secs);
	return 0;
}
