/* injdiag.c -- diagnostic for injcount: show WHAT changed.
 * If the changed pages are all-zero -> reclaim/refault artifact (false positive).
 * If they carry 16/32-byte ring records -> real MD injection.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>

#define PAGE 4096UL
#define PAT  0xA5A5A5A5u
#define WPP  (PAGE / sizeof(unsigned int))

int main(int argc, char **argv)
{
	long mb = (argc > 1) ? atol(argv[1]) : 16;
	long secs = (argc > 2) ? atol(argv[2]) : 10;
	size_t sz = (size_t)mb * 1024UL * 1024UL;
	unsigned long npages = sz / PAGE, i, j, modified = 0, shown = 0, zeroish = 0;
	unsigned int *p;
	volatile unsigned int *vp;

	p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { perror("mmap"); return 1; }
	for (i = 0; i < npages; i++) {
		unsigned int *pg = p + (i * WPP);
		for (j = 0; j < WPP; j++) pg[j] = PAT;
	}
	fprintf(stderr, "poisoned %lu pages, waiting %ld s\n", npages, secs);
	sleep(secs);

	vp = (volatile unsigned int *)p;
	for (i = 0; i < npages; i++) {
		unsigned long base = i * WPP, nz = 0;
		int hit = 0;
		for (j = 0; j < WPP; j++) {
			unsigned int v = vp[base + j];
			if (v != PAT) { hit = 1; if (v != 0) nz++; }
		}
		if (!hit) continue;
		modified++;
		if (nz == 0) zeroish++;
		if (shown < 3) {
			unsigned long k;
			printf("page %lu: nonzero_words=%lu  first16=", i, nz);
			for (k = 0; k < 16; k++) printf("%08x ", vp[base + k]);
			printf("\n");
			shown++;
		}
	}
	printf("RESULT pages=%lu modified=%lu all_zero=%lu mb=%ld secs=%ld\n",
	       npages, modified, zeroish, mb, secs);
	return 0;
}
