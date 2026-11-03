// funnelv2_selftest: positive control for funnelv2.ko (D27)
//
// Every group writes one payload into a fresh pipe and reads it back with a
// single read(fd, stack_buf, len).  pipe_read -> copy_page_to_iter -> copyout
// -> __arch_copy_to_user(dst=stack buf, src=pipe page, len).  A fresh pipe
// holds the payload in one page at offset 0, so the record offset inside the
// copy source equals the offset inside the payload.
//
// Groups (expected funnelv2 hot-ring hit):
//   G1 len=32   off=0x00  -> 32B family A0B2 at o=0
//   G2 len=64   off=0x10  -> 32B family A0B2 at o=0x10
//   G3 len=128  off=0x60  -> 32B family A0B2 at o=0x60
//   G4 len=0xc0 off=0xa0  -> 32B family A0B2 at o=0xa0 (last 32B that fits)
//   G5 len=0xd0 off=0xb0  -> 32B family A0B2 at o=0xb0 (D21 geometry: q7 slot)
//   G6 len=0xc0 off=0xb0  -> 16B core {len,ip} only; no 32B window fits at
//                            0xb0 (0xb0+32 > 0xc0), so this must increment
//                            core16 and must NOT produce a 32B record
//   G7 len=64   off=0x08, dst=buf+8 (8B-aligned) -> o0=8, hit at o=8
//
// Build: static aarch64-linux-musl (see build_bmods.sh).
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

static const unsigned char IP[4] = { 192, 168, 9, 145 };

/* A0B2 record: {u32 A, 0, u32 len, __be32 ip, 0} = 32 bytes */
static void put_record(unsigned char *p, uint32_t a, uint32_t len)
{
	memset(p, 0, 32);
	memcpy(p + 0, &a, 4);
	memcpy(p + 16, &len, 4);
	memcpy(p + 20, IP, 4);
}

/* 16B core: {u32 len, __be32 ip} */
static void put_core16(unsigned char *p, uint32_t len)
{
	memset(p, 0, 16);
	memcpy(p + 0, &len, 4);
	memcpy(p + 4, IP, 4);
}

static int run_group(const char *name, unsigned int len, unsigned int off,
		     unsigned int mis, int core16)
{
	unsigned char payload[256] __attribute__((aligned(16)));
	unsigned char buf[256] __attribute__((aligned(16)));
	unsigned char *dst = buf + mis;
	int pfd[2];
	ssize_t n;
	int ok;

	memset(payload, 0xaa, sizeof(payload));
	memset(buf, 0x55, sizeof(buf));
	if (core16)
		put_core16(payload + off, 0x680);
	else
		put_record(payload + off, 0x12345, 0x680);

	if (pipe(pfd) != 0) {
		perror("pipe");
		return 1;
	}
	if (write(pfd[1], payload, len) != (ssize_t)len) {
		perror("write");
		return 1;
	}
	n = read(pfd[0], dst, len);
	close(pfd[0]);
	close(pfd[1]);
	if (n != (ssize_t)len) {
		perror("read");
		return 1;
	}
	ok = memcmp(dst, payload, len) == 0;
	printf("group=%-16s len=%3u off=0x%02x mis=%u dst_mod16=%u "
	       "read=%zd ok=%d\n",
	       name, len, off, mis, (unsigned int)((uintptr_t)dst & 0xf),
	       n, ok);
	fflush(stdout);
	usleep(150000);		/* let a poller see the record */
	return ok ? 0 : 1;
}

int main(void)
{
	int rc = 0;

	printf("funnelv2_selftest pid=%d: expect 5 hot A0B2 records "
	       "(G1..G5), 1 core16 (G6), 1 hot A0B2 at o=8 (G7)\n", getpid());
	rc |= run_group("G1-32B@0",     32,  0x00, 0, 0);
	rc |= run_group("G2-64B@0x10",  64,  0x10, 0, 0);
	rc |= run_group("G3-128B@0x60", 128, 0x60, 0, 0);
	rc |= run_group("G4-0xc0@0xa0", 0xc0, 0xa0, 0, 0);
	rc |= run_group("G5-0xd0@0xb0", 0xd0, 0xb0, 0, 0);
	rc |= run_group("G6-0xc0-core16", 0xc0, 0xb0, 0, 1);
	rc |= run_group("G7-64B@8-mis8", 64, 0x08, 8, 0);
	printf("funnelv2_selftest: %s; now read /proc/funnelv2 "
	       "(comm=funnelv2_selftest)\n", rc ? "FAIL" : "DONE");
	return rc;
}
