/* variant: 4096-byte destination -- still crashes (not buffer adjacency). */
#include <stdio.h>
int main(void)
{
	char b[4096];
	unsigned long i;

	for (i = 0; i < 200000000UL; i++)
		snprintf(b, sizeof b, "%ld", (long)i);
	return (int)b[0];
}
