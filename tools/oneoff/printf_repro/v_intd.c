/* variant: %d instead of %ld -- still crashes (not the 64-bit path). */
#include <stdio.h>
int main(void)
{
	char b[24];
	unsigned long i;

	for (i = 0; i < 200000000UL; i++)
		snprintf(b, sizeof b, "%d", (int)i);
	return (int)b[0];
}
