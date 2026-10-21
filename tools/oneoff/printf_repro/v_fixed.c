/* variant: fixed value -- still crashes (not value dependent). */
#include <stdio.h>
int main(void)
{
	char b[24];
	unsigned long i;

	for (i = 0; i < 200000000UL; i++)
		snprintf(b, sizeof b, "%ld", (long)1566894);
	return (int)b[0];
}
