// pascan2.c -- U-G3: exact u32/u64 target scan over an arbitrary PA range via /dev/mem.
// usage: pascan2 <start_hex> <end_hex> <pa1>[,pa2...] [rounds]
// Prints every 4B-aligned word equal to any target (low or high half of a u64
// whose other half is also checked), plus qword context. Read-only.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

int main(int argc, char **argv)
{
  unsigned long start, end, t;
  unsigned long tl[16], pl[16];
  int nt = 0, ti, rounds = 1, r, hits = 0;
  int fd;
  if (argc < 4) { fprintf(stderr, "usage: %s start end pa[,pa..] [rounds]\n", argv[0]); return 1; }
  start = strtoul(argv[1], 0, 16); end = strtoul(argv[2], 0, 16);
  {
    char *p = argv[3], *q;
    while (p && nt < 16) {
      q = strchr(p, ',');
      if (q) *q = 0;
      tl[nt] = strtoul(p, 0, 16);
      pl[nt] = tl[nt] & ~0xfffUL;
      nt++;
      p = q ? q + 1 : 0;
    }
  }
  if (argc > 4) rounds = atoi(argv[4]);
  fd = open("/dev/mem", O_RDONLY | O_SYNC);
  if (fd < 0) { perror("mem"); return 1; }
  printf("PASCAN2 %lx-%lx nt=%d rounds=%d\n", start, end, nt, rounds);
  for (r = 0; r < rounds; r++) {
    unsigned long pa;
    for (pa = start & ~0xfffUL; pa + 0x1000 <= end; pa += 0x1000) {
      unsigned char *m = mmap(0, 0x1000, PROT_READ, MAP_SHARED, fd, pa);
      unsigned long off;
      if (m == MAP_FAILED) continue;
      for (off = 0; off + 4 <= 0x1000; off += 4) {
        unsigned int v = *(volatile unsigned int *)(m + off);
        int mt = 0;
        for (ti = 0; ti < nt; ti++)
          if (v == (unsigned int)tl[ti] || v == (unsigned int)pl[ti]) { mt = 1; break; }
        if (mt) {
          unsigned long q = *(volatile unsigned long *)(m + (off & ~7UL));
          printf("HIT pa=%lx off=%lx v=%x q=%016lx r=%d\n", pa, off, v, q, r);
          fflush(stdout);
          hits++;
        }
      }
      munmap(m, 0x1000);
    }
  }
  printf("PASCAN2 done hits=%d\n", hits);
  return 0;
}
