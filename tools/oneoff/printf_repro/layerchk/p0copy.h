#ifndef P0COPY_H
#define P0COPY_H
/* byte-wise copy: no memcpy, no SIMD, works with -mgeneral-regs-only */
static __attribute__((noinline)) void p0_bytecopy(void *d, const void *s, unsigned long n)
{
	unsigned char *dd = (unsigned char *)d;
	const unsigned char *ss = (const unsigned char *)s;
	for (unsigned long k = 0; k < n; k++) dd[k] = ss[k];
}
#endif
