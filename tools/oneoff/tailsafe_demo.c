/* tailsafe_demo.c -- show the placement difference the audit tool measures. */
#include <stdio.h>
#include "tailsafe.h"

struct blob { unsigned char b[300]; };

static struct blob          g_plain;      /* wherever the linker puts it  */
static TAILSAFE struct blob g_shielded;   /* page-aligned -> tail-immune  */

TAILSAFE_ASSERT(struct blob);

int main(void)
{
	printf("plain    %p pageoff=0x%03lx size=%zu\n", (void *)&g_plain,
	       (unsigned long)&g_plain & 0xfff, sizeof g_plain);
	printf("shielded %p pageoff=0x%03lx size=%zu\n", (void *)&g_shielded,
	       (unsigned long)&g_shielded & 0xfff, sizeof g_shielded);
	return 0;
}
