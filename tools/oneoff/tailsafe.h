/* tailsafe.h -- immunity to the page-tail writer (docs/SIGSEGV_ANALYSIS.md 11.2).
 *
 * The external writer lands 8/16 B at page offset 0xfc0 (sometimes 0xff0).  A
 * global object is therefore only at risk when its bytes intersect the last 64
 * bytes of its page.  Placing an object at a page boundary and keeping it below
 * 4032 bytes makes it structurally immune: no field can ever fall in that window.
 *
 * Usage:
 *     static TAILSAFE struct my_state g_state;
 *     TAILSAFE_ASSERT(struct my_state);
 *
 * Rules: the object must be a single global (not an array element), its size
 * must be <= 4032 bytes, and it must not be placed inside another aggregate.
 */
#ifndef TAILSAFE_H
#define TAILSAFE_H

#define TAILSAFE_PAGE 4096
#define TAILSAFE_TAIL 64
#define TAILSAFE_MAX  (TAILSAFE_PAGE - TAILSAFE_TAIL)   /* 4032 */

#define TAILSAFE __attribute__((aligned(TAILSAFE_PAGE)))

#define TAILSAFE_ASSERT(type) \
	_Static_assert(sizeof(type) <= TAILSAFE_MAX, \
		       "TAILSAFE object must fit in one page minus the 64-byte tail")

#endif
