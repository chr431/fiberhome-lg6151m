/* pffp.c -- false-positive check for the v2 va_list gate: 12-arg formats put
 * 8 args in registers and the rest on the stack, i.e. both va_arg paths. */
#include <stdio.h>
extern unsigned long __p0_va_guard_hits;

static int one(int a, int b, long c, const char *s, int d, int e, int f,
	       int g, int h, int i, int j, int k)
{
	char buf[256];
	return snprintf(buf, sizeof buf, "%d|%d|%ld|%s|%d|%d|%d|%d|%d|%d|%d|%d",
			a, b, c, s, d, e, f, g, h, i, j, k);
}

int main(void)
{
	long acc = 0, i;
	for (i = 0; i < 200000; i++)
		acc += one(1, 2, 3L, "x", 4, 5, 6, 7, 8, 9, 10, 11);
	printf("acc=%ld hits=%lu\n", acc, __p0_va_guard_hits);
	return 0;
}
