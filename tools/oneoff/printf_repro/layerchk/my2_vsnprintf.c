#include "stdio_impl.h"
#include <limits.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include "chk2.h"

struct cookie {
	char *s;
	size_t n;
};

#define MIN(a, b) ((a) < (b) ? (a) : (b))

static size_t sn_write(FILE *f, const unsigned char *s, size_t l)
{
	struct cookie *c = f->cookie;
	size_t k = MIN(c->n, f->wpos - f->wbase);
	if (k) {
		memcpy(c->s, f->wbase, k);
		c->s += k;
		c->n -= k;
	}
	k = MIN(c->n, l);
	if (k) {
		memcpy(c->s, s, k);
		c->s += k;
		c->n -= k;
	}
	*c->s = 0;
	f->wpos = f->wbase = f->buf;
	/* pretend to succeed, even if we discarded extra data */
	return l;
}

int vsnprintf(char *restrict s, size_t n, const char *restrict fmt, va_list ap)
{
	unsigned char buf[1];
	char dummy[1];
	struct cookie c = { .s = n ? s : dummy, .n = n ? n-1 : 0 };
	FILE f = {
		.lbf = EOF,
		.write = sn_write,
		.lock = -1,
		.buf = buf,
		.cookie = &c,
	};

	*c.s = 0;
	{
		const volatile unsigned long *w = (const volatile unsigned long *)&ap;
		g_src[0] = (unsigned long)&ap;
		g_src[1] = w[0]; g_src[2] = w[1]; g_src[3] = w[2]; g_src[4] = w[3];
	}
	{
		int __r = vfprintf(&f, fmt, ap);
		{
			const volatile unsigned long *w = (const volatile unsigned long *)&ap;
			if (w[0] != g_src[1] || w[1] != g_src[2] || w[2] != g_src[3] || w[3] != g_src[4])
				p0rpt("vsnprintf.src_changed", g_src[0], g_src[1], w[0], w[1], w[2]);
		}
		return __r;
	}
}
