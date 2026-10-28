/* pfpoison.c -- prove that the va_list gate converts a poisoned va_list into a
 * printed zero instead of a SIGSEGV.  The payload shapes are the ones the
 * external writer actually leaves in memory (SIGSEGV_ANALYSIS.md 11.2). */
#include <stdio.h>
#include <stdarg.h>

struct VL { void *stack, *gr_top, *vr_top; int gr_offs, vr_offs; };

static const unsigned long long pays[] = {
	0x8fae00008fa80000ULL,	/* {BAT base, ring base} this boot */
	0x909c1fa090980000ULL,	/* {BAT base, producer} earlier boot */
	0x90280c6090040000ULL,
	0xa75c0110a7580000ULL,
	0x0605040302010000ULL,	/* byte pattern */
	0x17074ULL,		/* small int */
	0x1c308ULL,		/* small int, 8-aligned */
	0ULL,
};

int main(void)
{
	static char b[256];
	unsigned i;
	int n = 0;

	for (i = 0; i < sizeof(pays) / sizeof(pays[0]); i++) {
		struct VL v;
		v.stack = (void *)pays[i];
		v.gr_top = (void *)pays[i];
		v.vr_top = (void *)pays[i];
		v.gr_offs = -48;
		v.vr_offs = -128;
		snprintf(b, sizeof b, "%d", 7);
		{
			va_list ap;
			__builtin_memcpy(&ap, &v, sizeof v);
			n += vfprintf(stdout, "%d %d %d\n", ap);
		}
	}
	fprintf(stderr, "poison done n=%d\n", n);
	return 0;
}
