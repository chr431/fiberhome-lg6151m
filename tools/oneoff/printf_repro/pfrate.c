/* pfrate.c -- tunable-exposure printf canary (SIGSEGV Phase 2 screening, 2026-10-26).
 *
 * Rationale: pfcanary (the historical oneoff) loops up to 2e8 snprintf calls and
 * dies within ~2 s whenever corruption is circulating.  That makes it a superb
 * episode DETECTOR but a saturated METRIC: it crashes ~100% of the time, so an
 * A/B has nothing to compare.  This variant runs exactly N calls and exits 0, so
 * the crash FRACTION over many runs estimates the corrupted-page encounter rate
 * with real dynamic range.  Tune N until the fraction sits in ~10-50%.
 *
 * Crash mechanism is identical to pfcanary (pop_arg va_arg on a corrupted
 * va_list; docs/SIGSEGV_ANALYSIS.md 12/13) -- only the exposure differs.
 *
 * Usage: pfrate <iters>
 *   exit 0   = survived N calls
 *   SIGSEGV  = hit a corrupted page (rc 139)
 */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	char b[24];
	unsigned long n = (argc > 1) ? strtoul(argv[1], 0, 10) : 100000UL;
	unsigned long i;

	if (n == 0)
		n = 100000UL;
	for (i = 0; i < n; i++)
		snprintf(b, sizeof b, "%ld", (long)i);
	return (int)b[0];
}
