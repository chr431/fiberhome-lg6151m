/* marker -- positive control for pascan2 (D25).
 *
 * Places four known 64-bit values (two of them also valid 32-bit patterns)
 * in a page-aligned .data page, prints its pid and the array address, then
 * pauses forever. pascan2 must find them in RAM.
 */
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

static volatile uint64_t magics[8] __attribute__((aligned(4096))) = {
    0xD25A5A5A5A5A5A5AULL,  /* 64-bit A */
    0x00000000D25B5B5BULL,  /* 32-bit A at offset 8 */
    0x123456789ABCDEF0ULL,  /* 64-bit B */
    0x00000000DEADBEEFULL,  /* 32-bit B at offset 24 */
    0x1111222233334444ULL,
    0x5555666677778888ULL,
    0x9999AAAABBBBCCCCULL,
    0xDDDDEEEEFFFF0000ULL,
};

int main(void)
{
    printf("MARKER pid=%d magics=%p\n", (int)getpid(), (void *)magics);
    fflush(stdout);
    for (;;)
        pause();
    return 0;
}
