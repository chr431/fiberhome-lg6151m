/* pfcanary.c -- minimal musl printf reproducer (2026-10-21).
 * Loop snprintf("%ld") with no fork, no I/O, no arrays.  On the device this
 * SIGSEGVs within ~2 s (about 1/1.6e6 calls) at -O0/-O1/-O2.
 * Crash: pop_arg's va_arg reads a corrupted va_list (__gr_top=0 / small
 * __stack); see docs/SIGSEGV_ANALYSIS.md section 12.
 */
#include <stdio.h>

int main(void)
{
	char b[24];
	unsigned long i;

	for (i = 0; i < 200000000UL; i++)
		snprintf(b, sizeof b, "%ld", (long)i);
	return (int)b[0];
}
