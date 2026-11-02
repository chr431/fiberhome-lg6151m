// funnel_selftest: positive control for funnelcatcher.ko (D23)
// Writes a 32-byte record-shaped payload into a pipe and reads it back with
// read(fd, buf, 32). pipe_read -> copy_page_to_iter -> copyout ->
// __arch_copy_to_user(dst=buf, src=pipe page, len=32), with src[8..16)==0 and
// src[24..32)==0 -- exactly the catcher's filter shape.
#include <unistd.h>
#include <string.h>
#include <stdio.h>

int main(void)
{
	unsigned char w[32], r[32];
	unsigned int *u = (unsigned int *)w;
	int p[2];
	ssize_t n;

	memset(w, 0, sizeof(w));
	u[0] = 0x12345;	/* A small (family B A0B2) */
	u[1] = 0;		/* word1 == 0 */
	u[2] = 0;
	u[3] = 0;
	u[4] = 0x680;		/* len=1664 in the record slot */
	u[5] = 0x9109a8c0;	/* 192.168.9.145 (__be32 in memory) */
	u[6] = 0;		/* word3 low == 0 */
	u[7] = 0;

	if (pipe(p) != 0) {
		perror("pipe");
		return 1;
	}
	if (write(p[1], w, 32) != 32) {
		perror("write");
		return 1;
	}
	memset(r, 0, sizeof(r));
	n = read(p[0], r, 32);
	if (n != 32) {
		perror("read");
		return 1;
	}
	printf("funnel_selftest: read=%zd match=%d\n", n, memcmp(w, r, 32) == 0);
	return 0;
}
