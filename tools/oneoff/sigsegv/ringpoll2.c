// ringpoll2.c -- U-G3 naming instrument: poll ALL known DMA ring pages for the
// victim slot PA (transient feeder catch). Pure /dev/mem DRAM reads, read-only.
// usage: ringpoll2 <target_pa_hex> <duration_s> [hits_cap]
// Rings hardcoded from ringdump2 (live decode 2026-11-05, this boot):
//   ACTIVE mtk_eth (eth@ffffff80019ec080): rx0 0xa4960000 (0x8000),
//   LRO 0x9a659000/0xa4a58000/0xa48ac000 (0x8000 each), aux 0x9044e000 (0x1000),
//   TX 0xa49d0000 (0x10000)
//   IDLE netsys-edma: RX 0x9a600000/0x9ca64000/0x9ca5c000 (0x2000),
//   TX 0x9b980000/0x9cc70000 (0x10000)
// Ring PAs are STABLE per boot only; rerun ringdump if rebooted.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
#include <sys/mman.h>

struct rng { const char *name; unsigned long pa, len; int tier; };
static struct rng R[] = {
  {"rx0",   0xa1030000UL, 0x8000UL,  0},
  {"tx",    0xa08a0000UL, 0x10000UL, 0},
  {"lro1",  0x9cdbd000UL, 0x8000UL,  1},
  {"lro2",  0xa10bc000UL, 0x8000UL,  1},
  {"lro3",  0x8f95e000UL, 0x8000UL,  1},
  {"aux5",  0x9d3f5000UL, 0x1000UL,  1},
  {"foe0",  0x9b400000UL, 0x100000UL, 2},
  {"foe1",  0x9b000000UL, 0x100000UL, 2},
  {"foe2",  0x9a780000UL, 0x100000UL, 2},
  {"blim",  0x9ffb0000UL, 0x10000UL, 2},
  {"wo0",   0xa1be0000UL, 0x10000UL, 2},
  {"wo1",   0xa1c20000UL, 0x10000UL, 2},
  {"wo2",   0xa1c60000UL, 0x10000UL, 2},
  {"wodt",  0xa30a0000UL, 0x10000UL, 2},
};
#define NR (sizeof(R)/sizeof(R[0]))

int main(int argc, char **argv)
{
  unsigned long tpa; unsigned long tlist[16], plist[16]; int nt = 0, ti;
  long dur;
  int cap = 64, nhit = 0, i;
  int fd;
  unsigned char *m[NR];
  struct timespec ts;
  long long t0, tnow;
  unsigned long page_pa;
  unsigned long iters = 0, sub = 0;

  if (argc < 3) { fprintf(stderr, "usage: %s target_pa_hex duration_s [cap]\n", argv[0]); return 1; }
  {
    char *p = argv[1], *q;
    while (p && nt < 16) {
      q = strchr(p, ',');
      if (q) *q = 0;
      tlist[nt] = strtoul(p, 0, 16);
      plist[nt] = tlist[nt] & ~0xfffUL;
      nt++;
      p = q ? q + 1 : 0;
    }
  }
  tpa = tlist[0];
  dur = atol(argv[2]);
  if (argc > 3) cap = atoi(argv[3]);
  page_pa = tpa & ~0xfffUL;

  fd = open("/dev/mem", O_RDONLY | O_SYNC);
  if (fd < 0) { perror("mem"); return 1; }
  for (i = 0; i < (int)NR; i++) {
    m[i] = mmap(0, R[i].len, PROT_READ, MAP_SHARED, fd, R[i].pa);
    if (m[i] == MAP_FAILED) { fprintf(stderr, "mmap %s failed\n", R[i].name); return 1; }
  }
  clock_gettime(CLOCK_MONOTONIC, &ts); t0 = ts.tv_sec*1000000000LL + ts.tv_nsec;
  printf("RINGPOLL2 nt=%d dur=%lds rings=%d\n", nt, dur, (int)NR);
  for (ti = 0; ti < nt; ti++) printf("TGT %lx page=%lx\n", tlist[ti], plist[ti]);

  for (;;) {
    int tier2 = (sub & 7) == 0;
    for (i = 0; i < (int)NR; i++) {
      unsigned long off;
      if (R[i].tier == 2 && !tier2) continue;
      for (off = 0; off + 4 <= R[i].len; off += 4) {
        unsigned int v = *(volatile unsigned int *)(m[i] + off);
        int mt = 0;
        for (ti = 0; ti < nt; ti++) if (v == (unsigned int)tlist[ti] || v == (unsigned int)plist[ti]) { mt = 1; break; }
        if (mt) {
          /* confirm high bits zero (full 64-bit PA) */
          unsigned long q = 0;
          if ((off & 7) == 4 && off >= 4) { /* high half of an aligned qword at off-4 */
            /* value is low half; check preceding word is 0 for a clean u64 PA */
          }
          clock_gettime(CLOCK_MONOTONIC, &ts); tnow = ts.tv_sec*1000000000LL + ts.tv_nsec;
          q = *(volatile unsigned long *)(m[i] + (off & ~7UL));
          printf("HIT %lld.%09ld ring=%s off=%lx v=%x q%lx=%lx iters=%lu sub=%lu\n",
                 tnow/1000000000, (long)(tnow%1000000000), R[i].name, off, v, off & ~7UL, q, iters, sub);
          fflush(stdout);
          if (++nhit >= cap) goto out;
        }
      }
    }
    iters++;
    if ((++sub & 0xffff) == 0) {
      clock_gettime(CLOCK_MONOTONIC, &ts); tnow = ts.tv_sec*1000000000LL + ts.tv_nsec;
      if ((tnow - t0) / 1000000000LL >= dur) break;
    }
  }
out:
  printf("RINGPOLL2 done iters=%lu hits=%d\n", iters, nhit);
  return 0;
}
