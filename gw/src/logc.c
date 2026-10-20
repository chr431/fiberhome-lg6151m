/*
 * logc.c -- static, defensive replacement for the vendor logread(8).
 *
 * Why: the vendor logread consumes logd's ubus fd stream with no frame
 * validation (it trusts blob_attr lengths blindly) and then feeds untrusted
 * bytes into the vendor musl printf/ctime path.  A single frame desync turns
 * into a SIGSEGV in libc (see docs/SIGSEGV_ANALYSIS.md).  This collector
 * speaks the same ubus protocol, but:
 *
 *   - every record is length-checked against the input window and the
 *     enclosing record before a single byte is trusted;
 *   - every blobmsg attribute is name/type/length checked; all five
 *     attributes (time,msg,id,priority,source) must be present exactly once
 *     and the attribute walk must end exactly at the record boundary;
 *   - timestamps are range-checked before formatting (no ctime/asctime_r:
 *     the time string is produced with localtime_r+strftime into a large
 *     buffer);
 *   - any violation drops the record, resynchronises at the next plausible
 *     record boundary and increments counters (surfaced via --stats-file).
 *
 * It is linked statically (zig cc -target aarch64-linux-musl) so the vendor
 * libc is not part of this process at all.
 *
 * CLI (compatible subset of logread):
 *   -l N        only the last N records
 *   -f          follow (stream, no oneshot)
 *   -F FILE     append to FILE instead of stdout
 *   -S KB       rotate FILE when it grows beyond KB (logread -S)
 *   -t          prepend [epoch.millis] like logread -t
 *   -e REGEX    only print records whose msg matches REGEX
 *   -s PATH     ubus socket (default /var/run/ubus/ubus.sock)
 *   --stats-file FILE   write key=value counters at exit / every 4096 frames
 *   --stdin     parse a raw record stream from stdin (offline test mode)
 *   --dump-raw FILE     keep the raw stream bytes (capped) for replay
 *   --raw-max BYTES     cap for --dump-raw (default 8 MiB)
 *   --selftest  run the frame parser against synthetic valid/malformed streams
 *   -V          version
 *
 * v1.2 -- stability P1-2 hardening:
 *   - SIGSEGV/SIGBUS/SIGABRT/SIGILL handler on an alternate stack writes a
 *     breadcrumb (/tmp/logc.crash): signal, frame offset, frame length, buffer
 *     fill, emitted frame count, uptime.  The next unexplained crash becomes
 *     an attributable frame instead of an opaque aee NE.
 *   - --dump-raw keeps the exact stream for offline replay via --stdin.
 *   - --selftest exercises the parser on-device (no ubus needed).
 *   - ubus message buffers moved off per-call stack frames.
 *
 * v1.0 -- initial defensive collector.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <regex.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define LOGC_VERSION "1.2"

/* ---- ubus wire protocol (only what we need) ---------------------------- */

struct ubus_hdr {
	uint8_t version;
	uint8_t type;
	uint16_t seq;	/* BE on wire */
	uint32_t peer;	/* BE on wire */
} __attribute__((packed));

enum {
	UBUS_MSG_HELLO = 0,
	UBUS_MSG_STATUS = 1,
	UBUS_MSG_DATA = 2,
	UBUS_MSG_PING = 3,
	UBUS_MSG_LOOKUP = 4,
	UBUS_MSG_INVOKE = 5,
};

enum {
	UBUS_ATTR_STATUS = 1,
	UBUS_ATTR_OBJPATH = 2,
	UBUS_ATTR_OBJID = 3,
	UBUS_ATTR_METHOD = 4,
	UBUS_ATTR_DATA = 7,
};

#define UBUS_MAX_MSG 65536

/* blob_attr: BE32 (id<<24 | len); len includes the 4-byte header. */
#define BLOB_EXTENDED 0x80000000u
#define BLOB_ID_MASK  0x7f000000u
#define BLOB_LEN_MASK 0x00ffffffu

/* blobmsg types */
enum {
	BLOBMSG_TYPE_UNSPEC = 0,
	BLOBMSG_TYPE_ARRAY = 1,
	BLOBMSG_TYPE_TABLE = 2,
	BLOBMSG_TYPE_STRING = 3,
	BLOBMSG_TYPE_INT64 = 4,
	BLOBMSG_TYPE_INT32 = 5,
	BLOBMSG_TYPE_INT16 = 6,
	BLOBMSG_TYPE_INT8 = 7,
};

static inline uint16_t rd_be16(const void *p)
{
	uint16_t v;
	memcpy(&v, p, sizeof(v));
	return be16toh(v);
}

static inline uint32_t rd_be32(const void *p)
{
	uint32_t v;
	memcpy(&v, p, sizeof(v));
	return be32toh(v);
}

static inline uint64_t rd_be64(const void *p)
{
	uint64_t v;
	memcpy(&v, p, sizeof(v));
	return be64toh(v);
}

/* ---- counters / logging ------------------------------------------------ */

static struct {
	unsigned long long frames;
	unsigned long long bytes;
	unsigned long long bad_frames;
	unsigned long long resyncs;
	unsigned long long dropped_bytes;
	unsigned long long bad_time;
	unsigned long long bad_attrs;
	unsigned long long filtered;
	unsigned long long io_errors;
} st;

static int debug;
static const char *stats_file;
static volatile sig_atomic_t stop_flag;

/* ---- v1.2: crash breadcrumb ------------------------------------------- */
#ifndef SIGSTKSZ
#define SIGSTKSZ 8192
#endif
static const char *crash_path = "/tmp/logc.crash";
static volatile sig_atomic_t cr_off = -1;	/* frame offset in the buffer */
static volatile sig_atomic_t cr_flen = -1;	/* claimed frame length */
static volatile sig_atomic_t cr_len = -1;	/* bytes currently buffered */
static volatile sig_atomic_t cr_frames = 0;	/* records emitted so far */

static size_t put_str(char *b, size_t n, size_t cap, const char *s)
{
	while (*s && n < cap)
		b[n++] = *s++;
	return n;
}

static size_t put_num(char *b, size_t n, size_t cap, long v)
{
	char t[24];
	size_t k = 0;
	unsigned long u;

	if (v < 0) {
		if (n < cap)
			b[n++] = '-';
		u = (unsigned long)(-v);
	} else {
		u = (unsigned long)v;
	}
	do {
		t[k++] = (char)('0' + (u % 10));
		u /= 10;
	} while (u && k < sizeof(t));
	while (k && n < cap)
		b[n++] = t[--k];
	return n;
}

static void on_crash(int sig)
{
	char b[256];
	size_t n = 0;
	int fd;

	n = put_str(b, n, sizeof(b), "logc crash: version=" LOGC_VERSION
		    " sig=");
	n = put_num(b, n, sizeof(b), sig);
	n = put_str(b, n, sizeof(b), " pid=");
	n = put_num(b, n, sizeof(b), (long)getpid());
	n = put_str(b, n, sizeof(b), " frame_off=");
	n = put_num(b, n, sizeof(b), (long)cr_off);
	n = put_str(b, n, sizeof(b), " frame_len=");
	n = put_num(b, n, sizeof(b), (long)cr_flen);
	n = put_str(b, n, sizeof(b), " buf_len=");
	n = put_num(b, n, sizeof(b), (long)cr_len);
	n = put_str(b, n, sizeof(b), " frames_emitted=");
	n = put_num(b, n, sizeof(b), (long)cr_frames);
	n = put_str(b, n, sizeof(b), " uptime_s=");
	{
		struct timespec ts;
		long up = -1;
		if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
			up = (long)ts.tv_sec;
		n = put_num(b, n, sizeof(b), up);
	}
	n = put_str(b, n, sizeof(b), "\n");

	fd = open(crash_path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
	if (fd >= 0) {
		ssize_t r = write(fd, b, n);
		(void)r;
		close(fd);
	}
	_exit(128 + sig);
}

static void install_crash_handler(void)
{
	static char alt[SIGSTKSZ * 2];
	struct sigaction sa;
	stack_t ss;

	memset(&ss, 0, sizeof(ss));
	ss.ss_sp = alt;
	ss.ss_size = sizeof(alt);
	(void)sigaltstack(&ss, NULL);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_crash;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_ONSTACK | SA_RESETHAND;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);
	sigaction(SIGFPE, &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
}

static void dbg(const char *fmt, ...)
{
	va_list ap;

	if (!debug)
		return;
	va_start(ap, fmt);
	fprintf(stderr, "logc: ");
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

static void write_stats(void)
{
	char tmp[256];
	int fd, n;

	if (!stats_file)
		return;
	n = snprintf(tmp, sizeof(tmp),
		     "frames=%llu bytes=%llu bad_frames=%llu resyncs=%llu "
		     "dropped_bytes=%llu bad_time=%llu bad_attrs=%llu "
		     "filtered=%llu io_errors=%llu\n",
		     st.frames, st.bytes, st.bad_frames, st.resyncs,
		     st.dropped_bytes, st.bad_time, st.bad_attrs,
		     st.filtered, st.io_errors);
	fd = open(stats_file, O_CREAT | O_WRONLY | O_TRUNC, 0644);
	if (fd < 0)
		return;
	if (write(fd, tmp, (size_t)n) != n)
		(void)0;
	close(fd);
}

static void on_signal(int sig)
{
	(void)sig;
	stop_flag = 1;
}

static int write_all(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;

	while (len) {
		ssize_t n = write(fd, p, len);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			return -1;
		p += n;
		len -= (size_t)n;
	}
	return 0;
}

/* ---- output ------------------------------------------------------------ */

static int out_fd = STDOUT_FILENO;
static const char *out_path;
static long out_limit;		/* bytes, 0 = no rotation */

/* v1.2: raw stream dump for offline replay (--dump-raw) */
static const char *raw_path;
static FILE *raw_fp;
static unsigned long long raw_max = 8ULL << 20;
static unsigned long long raw_bytes;

static void raw_dump(const void *p, size_t n)
{
	if (!raw_path)
		return;
	if (!raw_fp) {
		raw_fp = fopen(raw_path, "wb");
		if (!raw_fp)
			return;
	}
	if (raw_bytes >= raw_max)
		return;
	if (raw_bytes + n > raw_max)
		n = (size_t)(raw_max - raw_bytes);
	if (n && fwrite(p, 1, n, raw_fp) == n) {
		raw_bytes += n;
		fflush(raw_fp);
	}
}

static int open_output(void)
{
	if (!out_path)
		return 0;
	out_fd = open(out_path, O_CREAT | O_WRONLY | O_APPEND, 0600);
	if (out_fd < 0) {
		fprintf(stderr, "logc: open %s: %s\n", out_path, strerror(errno));
		return -1;
	}
	return 0;
}

static void maybe_rotate(void)
{
	struct stat sb;
	char *old;

	if (!out_path || !out_limit)
		return;
	if (fstat(out_fd, &sb) != 0 || sb.st_size <= out_limit)
		return;
	old = malloc(strlen(out_path) + 5);
	if (!old)
		return;
	sprintf(old, "%s.old", out_path);
	close(out_fd);
	rename(out_path, old);
	free(old);
	if (open_output() != 0)
		out_fd = STDOUT_FILENO;
}

/* ---- timezone ---------------------------------------------------------- */

/* The vendor libc reads the POSIX TZ string from /etc/TZ; zig's musl reads
 * TZ or /etc/localtime.  This image keeps the TZ string in /etc/TZ (symlink
 * to /tmp/TZ) and has no /etc/localtime data file, so seed TZ ourselves to
 * keep output byte-identical with logread. */
static void init_timezone(void)
{
	char buf[128];
	FILE *f;

	if (getenv("TZ")) {
		tzset();
		return;
	}
	f = fopen("/etc/TZ", "r");
	if (f) {
		if (fgets(buf, sizeof(buf), f)) {
			size_t n = strlen(buf);
			while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
				     buf[n - 1] == ' ' || buf[n - 1] == '\t'))
				buf[--n] = 0;
			if (n)
				setenv("TZ", buf, 1);
		}
		fclose(f);
	}
	tzset();
}

/* ---- syslog name tables (same text as libc facilitynames/prioritynames) */

static const char *const facility_name[24] = {
	"kern", "user", "mail", "daemon", "auth", "syslog", "lpr", "news",
	"uucp", "cron", "authpriv", "ftp", "ntp", "security", "console",
	"solaris-cron", "local0", "local1", "local2", "local3", "local4",
	"local5", "local6", "local7",
};

static const char *const priority_name[8] = {
	"emerg", "alert", "crit", "err", "warning", "notice", "info", "debug",
};

static const char *fac_name(unsigned int fac)
{
	return fac < 24 ? facility_name[fac] : "<unknown>";
}

static const char *pri_name(unsigned int pri)
{
	return pri < 8 ? priority_name[pri] : "<unknown>";
}

/* ---- record model ------------------------------------------------------ */

struct record {
	uint64_t time_ms;
	uint32_t id;
	uint32_t priority;
	uint32_t source;
	const char *msg;
	size_t msg_len;
};

#define MIN_FRAME 32
#define MAX_FRAME 65536
#define MAX_MSG 8192

/* 1 = attribute list ends exactly at end, 0 = malformed */
static int parse_record(const uint8_t *p, size_t avail, struct record *r)
{
	uint32_t hdr, flen;
	size_t off, end;
	int seen_time = 0, seen_msg = 0, seen_id = 0, seen_prio = 0, seen_src = 0;

	if (avail < 4)
		return 0;
	hdr = rd_be32(p);
	if ((hdr & BLOB_EXTENDED) || ((hdr & BLOB_ID_MASK) >> 24) != 0)
		return 0;
	flen = hdr & BLOB_LEN_MASK;
	if (flen < 4 || flen > MAX_FRAME || flen > avail)
		return 0;

	off = 4;
	end = flen;
	memset(r, 0, sizeof(*r));

	while (off < end) {
		uint32_t ahdr, alen, plen, type;
		const uint8_t *attr, *data;
		size_t hlen, dlen, nl;
		const char *name;

		if (end - off < 4)
			return 0;
		ahdr = rd_be32(p + off);
		if (!(ahdr & BLOB_EXTENDED))
			return 0;
		type = (ahdr & BLOB_ID_MASK) >> 24;
		alen = ahdr & BLOB_LEN_MASK;
		if (alen < 4 + 3 || alen > end - off)
			return 0;
		attr = p + off + 4;
		plen = alen - 4;
		nl = rd_be16(attr);
		if (nl == 0 || nl > plen - 3)
			return 0;
		if (attr[2 + nl] != 0)
			return 0;
		name = (const char *)(attr + 2);
		hlen = (2 + nl + 1 + 3) & ~(size_t)3;
		if (hlen > plen)
			return 0;
		data = attr + hlen;
		dlen = plen - hlen;

		if (!strcmp(name, "time")) {
			if (seen_time++ || type != BLOBMSG_TYPE_INT64 || dlen != 8)
				return 0;
			r->time_ms = rd_be64(data);
			/* Accept 1970..2100: pre-NTP boot records legitimately
			 * carry a 1970-ish wall clock.  Corrupted "msg bytes as
			 * timestamp" values are ~1e16 ms, far above this. */
			if (r->time_ms > 4102444800000ULL) {
				st.bad_time++;
				return 0;
			}
		} else if (!strcmp(name, "msg")) {
			if (seen_msg++ || type != BLOBMSG_TYPE_STRING ||
			    dlen < 1 || dlen > MAX_MSG)
				return 0;
			if (data[dlen - 1] != 0)
				return 0;
			if (memchr(data, 0, dlen - 1) != NULL)
				return 0;
			r->msg = (const char *)data;
			r->msg_len = dlen - 1;
		} else if (!strcmp(name, "id")) {
			if (seen_id++ || type != BLOBMSG_TYPE_INT32 || dlen != 4)
				return 0;
			r->id = rd_be32(data);
		} else if (!strcmp(name, "priority")) {
			if (seen_prio++ || type != BLOBMSG_TYPE_INT32 || dlen != 4)
				return 0;
			r->priority = rd_be32(data);
			if (r->priority > 0xff) {
				st.bad_attrs++;
				return 0;
			}
		} else if (!strcmp(name, "source")) {
			if (seen_src++ || type != BLOBMSG_TYPE_INT32 || dlen != 4)
				return 0;
			r->source = rd_be32(data);
			if (r->source > 2) {
				st.bad_attrs++;
				return 0;
			}
		} else {
			return 0;	/* unknown attribute: reject the frame */
		}

		off += (alen + 3) & ~(size_t)3;
	}

	if (off != end)
		return 0;
	if (!seen_time || !seen_msg || !seen_id || !seen_prio || !seen_src)
		return 0;
	return 1;
}

/* Format one record exactly like logread's stdout path:
 *   "<ctime> <facility>.<priority>[ kernel:] <msg>\n"
 * (ctime is rebuilt with localtime_r/strftime; no asctime_r/ctime call).
 */
static int emit_record(const struct record *r, int with_ts, regex_t *re)
{
	char tbuf[64];
	char line[8192];
	struct tm tm;
	time_t sec = (time_t)(r->time_ms / 1000);
	size_t n;
	int len;

	if (re && regexec(re, r->msg, 0, NULL, 0) == REG_NOMATCH) {
		st.filtered++;
		return 0;
	}
	if (!localtime_r(&sec, &tm))
		return -1;
	if (!strftime(tbuf, sizeof(tbuf), "%a %b %e %H:%M:%S %Y", &tm))
		return -1;

	len = snprintf(line, sizeof(line), "%s ", tbuf);
	if (len < 0 || (size_t)len >= sizeof(line))
		return -1;
	if (with_ts) {
		int k = snprintf(line + len, sizeof(line) - (size_t)len,
				 "[%lld.%03u] ", (long long)sec,
				 (unsigned)(r->time_ms % 1000));
		if (k < 0 || (size_t)k >= sizeof(line) - (size_t)len)
			return -1;
		len += k;
	}
	n = (size_t)len;
	len = snprintf(line + n, sizeof(line) - n, "%s.%s%s %s\n",
		       fac_name((r->priority >> 3) & 0x1f),
		       pri_name(r->priority & 7),
		       r->source == 0 ? " kernel:" : "",
		       r->msg);
	if (len < 0 || (size_t)len >= sizeof(line) - n)
		return -1;
	n += (size_t)len;

	maybe_rotate();
	if (write_all(out_fd, line, n) != 0) {
		st.io_errors++;
		return -1;
	}
	st.frames++;
	st.bytes += n;
	cr_frames = (sig_atomic_t)(st.frames & 0x7fffffff);
	if ((st.frames & 0xfff) == 0)
		write_stats();
	return 0;
}

/* Consume as many complete records as possible. Returns bytes consumed,
 * or SIZE_MAX on a fatal output error. */
static size_t consume_records(const uint8_t *buf, size_t len, int with_ts,
			      regex_t *re, int at_eof)
{
	size_t off = 0;
	int in_sync = 1;

	while (off + 4 <= len) {
		uint32_t hdr = rd_be32(buf + off);
		uint32_t flen = hdr & BLOB_LEN_MASK;
		struct record r;

		cr_off = (sig_atomic_t)off;
		cr_flen = (sig_atomic_t)flen;

		if ((hdr & BLOB_EXTENDED) || ((hdr & BLOB_ID_MASK) >> 24) != 0 ||
		    flen < MIN_FRAME || flen > MAX_FRAME) {
			/* not a plausible record header: resync byte-wise */
			if (in_sync) {
				st.bad_frames++;
				in_sync = 0;
			}
			off++;
			st.dropped_bytes++;
			continue;
		}
		if (off + flen > len) {
			if (!in_sync || at_eof) {
				/* during resync / at EOF a plausible-looking
				 * length is not a reason to wait forever */
				if (in_sync) {
					st.bad_frames++;
					in_sync = 0;
				}
				off++;
				st.dropped_bytes++;
				continue;
			}
			break;	/* wait for the rest of the record */
		}

		if (!parse_record(buf + off, len - off, &r)) {
			if (in_sync) {
				st.bad_frames++;
				in_sync = 0;
			}
			off++;
			st.dropped_bytes++;
			continue;
		}

		if (!in_sync) {
			st.resyncs++;
			in_sync = 1;
			dbg("resynchronised at offset %zu (frame len %u)", off, flen);
		}
		if (emit_record(&r, with_ts, re) != 0)
			return SIZE_MAX;
		off += flen;
	}

	return off;
}

/* ---- ubus client ------------------------------------------------------- */

struct mbuf {
	uint8_t *p;
	size_t len;
	size_t cap;
};

static int mb_reserve(struct mbuf *b, size_t add)
{
	if (b->len + add > b->cap)
		return -1;
	return 0;
}

static int mb_attr(struct mbuf *b, unsigned int id, const void *data, size_t len)
{
	uint32_t v = htobe32(((id & 0x7f) << 24) | (uint32_t)(len + 4));
	size_t pad = ((len + 4) + 3) & ~(size_t)3;

	if (mb_reserve(b, pad))
		return -1;
	memcpy(b->p + b->len, &v, 4);
	if (len)
		memcpy(b->p + b->len + 4, data, len);
	memset(b->p + b->len + 4 + len, 0, pad - 4 - len);
	b->len += pad;
	return 0;
}

static int mb_str(struct mbuf *b, unsigned int id, const char *s)
{
	return mb_attr(b, id, s, strlen(s) + 1);
}

static int mb_u32(struct mbuf *b, unsigned int id, uint32_t v)
{
	uint32_t be = htobe32(v);
	return mb_attr(b, id, &be, 4);
}

/* blobmsg named attribute (extended flag + name header) */
static int bm_attr(struct mbuf *b, unsigned int type, const char *name,
		   const void *data, size_t len)
{
	size_t nl = strlen(name);
	size_t hlen = (2 + nl + 1 + 3) & ~(size_t)3;
	size_t plen = hlen + len;
	size_t pad = (plen + 4 + 3) & ~(size_t)3;
	uint32_t v = htobe32(BLOB_EXTENDED | ((type & 0x7f) << 24) |
			     (uint32_t)(plen + 4));
	uint16_t nlen = htobe16((uint16_t)nl);

	if (mb_reserve(b, pad))
		return -1;
	memcpy(b->p + b->len, &v, 4);
	memcpy(b->p + b->len + 4, &nlen, 2);
	memcpy(b->p + b->len + 6, name, nl);
	memset(b->p + b->len + 6 + nl, 0, hlen - 2 - nl);
	if (len)
		memcpy(b->p + b->len + 4 + hlen, data, len);
	memset(b->p + b->len + 4 + hlen + len, 0, pad - 4 - plen);
	b->len += pad;
	return 0;
}

static int bm_u32(struct mbuf *b, const char *name, uint32_t v)
{
	uint32_t be = htobe32(v);
	return bm_attr(b, BLOBMSG_TYPE_INT32, name, &be, 4);
}

static int bm_u8(struct mbuf *b, const char *name, uint8_t v)
{
	return bm_attr(b, BLOBMSG_TYPE_INT8, name, &v, 1);
}

static int send_msg(int fd, uint8_t type, uint16_t seq, uint32_t peer,
		    const uint8_t *attrs, size_t alen)
{
	struct ubus_hdr h;
	uint8_t buf[8 + 4 + UBUS_MAX_MSG];
	size_t total;
	uint32_t v = htobe32((uint32_t)alen + 4);

	if (alen + 4 > UBUS_MAX_MSG)
		return -1;
	memset(&h, 0, sizeof(h));
	h.version = 0;
	h.type = type;
	h.seq = htobe16(seq);
	h.peer = htobe32(peer);
	memcpy(buf, &h, 8);
	memcpy(buf + 8, &v, 4);
	memcpy(buf + 12, attrs, alen);
	total = 12 + alen;
	return write_all(fd, buf, total);
}

/* Read one ubus message. Returns 0 on success, -1 on error/EOF. */
static int recv_msg(int fd, struct ubus_hdr *h, uint8_t *payload, size_t cap,
		    size_t *plen, int *fd_out)
{
	uint8_t first[12];
	struct iovec iov;
	struct msghdr mh;
	uint8_t cbuf[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *cmsg;
	ssize_t n;
	uint32_t v, alen;
	size_t need;

	if (fd_out)
		*fd_out = -1;
	memset(&mh, 0, sizeof(mh));
	memset(cbuf, 0, sizeof(cbuf));
	iov.iov_base = first;
	iov.iov_len = sizeof(first);
	mh.msg_iov = &iov;
	mh.msg_iovlen = 1;
	mh.msg_control = cbuf;
	mh.msg_controllen = sizeof(cbuf);
	do {
		n = recvmsg(fd, &mh, MSG_WAITALL);
	} while (n < 0 && errno == EINTR);
	if (n != (ssize_t)sizeof(first))
		return -1;

	if (fd_out) {
		for (cmsg = CMSG_FIRSTHDR(&mh); cmsg; cmsg = CMSG_NXTHDR(&mh, cmsg)) {
			if (cmsg->cmsg_level == SOL_SOCKET &&
			    cmsg->cmsg_type == SCM_RIGHTS &&
			    cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
				memcpy(fd_out, CMSG_DATA(cmsg), sizeof(int));
			}
		}
	}

	memcpy(h, first, 8);
	h->seq = be16toh(h->seq);
	h->peer = be32toh(h->peer);
	v = rd_be32(first + 8);
	alen = v & BLOB_LEN_MASK;
	if (h->version != 0 || (v & BLOB_EXTENDED) ||
	    ((v & BLOB_ID_MASK) >> 24) != 0 || alen < 4 || alen > cap + 4)
		return -1;
	need = alen - 4;
	if (need) {
		size_t got = 0;
		while (got < need) {
			ssize_t k = read(fd, payload + got, need - got);
			if (k < 0 && errno == EINTR)
				continue;
			if (k <= 0)
				return -1;
			got += (size_t)k;
		}
	}
	*plen = need;
	return 0;
}

/* Find a top-level ubus attribute (plain blob, no name) by id. */
static const uint8_t *find_attr(const uint8_t *p, size_t len, unsigned int id,
				size_t *out_len)
{
	size_t off = 0;

	while (off + 4 <= len) {
		uint32_t v = rd_be32(p + off);
		uint32_t alen = v & BLOB_LEN_MASK;
		unsigned int aid = (v & BLOB_ID_MASK) >> 24;

		if (alen < 4 || alen > len - off)
			return NULL;
		if (aid == id && !(v & BLOB_EXTENDED)) {
			if (out_len)
				*out_len = alen - 4;
			return p + off + 4;
		}
		off += (alen + 3) & ~(size_t)3;
	}
	return NULL;
}

static int connect_ubus(const char *path)
{
	struct sockaddr_un sa;
	struct timeval tv = { 10, 0 };
	int fd;

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	/* v1.1: bounded handshake — a wedged ubusd/logd must not hang the
	 * caller (log_keeper runs this synchronously every 30s). */
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof(sa.sun_path)) {
		close(fd);
		return -1;
	}
	strcpy(sa.sun_path, path);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

/* v1.2: one static message buffer instead of a 64 KB array per call frame
 * (three such frames previously coexisted on the stack of the ubus path). */
static uint8_t ubus_payload[UBUS_MAX_MSG];

static int ubus_hello(int fd)
{
	struct ubus_hdr h;
	size_t plen;
	int rfd;

	if (recv_msg(fd, &h, ubus_payload, sizeof(ubus_payload), &plen, &rfd) != 0)
		return -1;
	if (rfd >= 0)
		close(rfd);
	if (h.type != UBUS_MSG_HELLO)
		return -1;
	return 0;
}

static int ubus_lookup(int fd, const char *path, uint32_t *id)
{
	uint8_t attrs[256];
	struct mbuf b = { attrs, 0, sizeof(attrs) };
	struct ubus_hdr h;
	size_t plen;
	int rfd, tries;

	if (mb_str(&b, UBUS_ATTR_OBJPATH, path) != 0)
		return -1;
	if (send_msg(fd, UBUS_MSG_LOOKUP, 1, 0, attrs, b.len) != 0)
		return -1;

	for (tries = 0; tries < 16; tries++) {
		const uint8_t *a;
		size_t alen;
		if (recv_msg(fd, &h, ubus_payload, sizeof(ubus_payload), &plen, &rfd) != 0)
			return -1;
		if (rfd >= 0)
			close(rfd);
		if (h.type == UBUS_MSG_DATA && h.seq == 1) {
			a = find_attr(ubus_payload, plen, UBUS_ATTR_OBJID, &alen);
			if (!a || alen != 4)
				return -1;
			*id = rd_be32(a);
			return 0;
		}
		if (h.type == UBUS_MSG_STATUS && h.seq == 1)
			return -1;
	}
	return -1;
}

/* Ask logd for a stream fd. Returns fd >= 0 or -1. */
static int ubus_open_log_stream(int fd, uint32_t objid, int follow,
				unsigned int lines, int *out_fd)
{
	uint8_t inner[128], attrs[512];
	struct mbuf ib = { inner, 0, sizeof(inner) };
	struct mbuf b = { attrs, 0, sizeof(attrs) };
	struct ubus_hdr h;
	size_t plen;
	int rfd, tries, got = -1;

	if (bm_u8(&ib, "stream", 1) != 0 ||
	    bm_u8(&ib, "oneshot", follow ? 0 : 1) != 0)
		return -1;
	if (lines || follow) {
		if (bm_u32(&ib, "lines", lines) != 0)
			return -1;
	}
	if (mb_u32(&b, UBUS_ATTR_OBJID, objid) != 0 ||
	    mb_str(&b, UBUS_ATTR_METHOD, "read") != 0 ||
	    mb_attr(&b, UBUS_ATTR_DATA, inner, ib.len) != 0)
		return -1;
	if (send_msg(fd, UBUS_MSG_INVOKE, 2, objid, attrs, b.len) != 0)
		return -1;

	for (tries = 0; tries < 16; tries++) {
		if (recv_msg(fd, &h, ubus_payload, sizeof(ubus_payload), &plen, &rfd) != 0) {
			if (got >= 0)
				close(got);
			return -1;
		}
		if (rfd >= 0) {
			if (got >= 0)
				close(got);
			got = rfd;
		}
		if (h.type == UBUS_MSG_STATUS && h.seq == 2) {
			const uint8_t *a;
			size_t alen;
			a = find_attr(ubus_payload, plen, UBUS_ATTR_STATUS, &alen);
			if (a && alen == 4 && rd_be32(a) == 0 && got >= 0) {
				*out_fd = got;
				return 0;
			}
			if (got >= 0)
				close(got);
			return -1;
		}
	}
	if (got >= 0)
		close(got);
	return -1;
}

/* ---- stream reader ----------------------------------------------------- */

static int read_stream_fd(int fd, int with_ts, regex_t *re, int follow)
{
	uint8_t *buf;
	size_t cap = 1 << 20, len = 0;
	int eof = 0;
	time_t last_data = time(NULL);

	buf = malloc(cap);
	if (!buf)
		return -1;

	for (;;) {
		size_t used;

		if (stop_flag)
			break;
		used = consume_records(buf, len, with_ts, re, eof);

		if (used == SIZE_MAX) {
			st.io_errors++;
			free(buf);
			return -1;
		}
		if (used) {
			memmove(buf, buf + used, len - used);
			len -= used;
		}
		if (eof) {
			if (len)
				dbg("discarding %zu trailing bytes at EOF", len);
			break;
		}
		if (len == cap) {
			/* no progress on a full buffer: drop the oldest byte */
			memmove(buf, buf + 1, cap - 1);
			len--;
			st.dropped_bytes++;
			continue;
		}

		{
			struct pollfd pfd = { .fd = fd, .events = POLLIN };
			int pr = poll(&pfd, 1, 1000);
			ssize_t n;
			if (pr < 0) {
				if (errno == EINTR)
					continue;
				break;
			}
			if (pr == 0) {
				/* oneshot must not wait forever on a wedged logd */
				if (!follow && time(NULL) - last_data > 60) {
					dbg("oneshot idle timeout");
					break;
				}
				continue;
			}
			if (stop_flag)
				break;
			n = read(fd, buf + len, cap - len);
			if (n < 0) {
				if (errno == EINTR || errno == EAGAIN)
					continue;
				st.io_errors++;
				break;
			}
			if (n == 0) {
				eof = 1;
				continue;
			}
			last_data = time(NULL);
			len += (size_t)n;
			cr_len = (sig_atomic_t)len;
			raw_dump(buf + len - (size_t)n, (size_t)n);
		}
	}

	/* final partial data is never trusted */
	if (len)
		st.dropped_bytes += len;
	free(buf);
	return 0;
}

/* ---- main -------------------------------------------------------------- */

/* ---- v1.2: on-device parser selftest ----------------------------------- */

static size_t mk_frame(uint8_t *b, size_t cap, uint64_t tms, uint32_t id,
		       uint32_t prio, uint32_t src, const char *msg)
{
	struct mbuf mb;
	uint64_t be64;
	uint32_t be, hdr;

	if (cap < 8)
		return 0;
	mb.p = b + 4;
	mb.len = 0;
	mb.cap = cap - 4;
	be64 = htobe64(tms);
	if (bm_attr(&mb, BLOBMSG_TYPE_INT64, "time", &be64, 8) != 0)
		return 0;
	if (bm_attr(&mb, BLOBMSG_TYPE_STRING, "msg", msg, strlen(msg) + 1) != 0)
		return 0;
	be = htobe32(id);
	if (bm_attr(&mb, BLOBMSG_TYPE_INT32, "id", &be, 4) != 0)
		return 0;
	be = htobe32(prio);
	if (bm_attr(&mb, BLOBMSG_TYPE_INT32, "priority", &be, 4) != 0)
		return 0;
	be = htobe32(src);
	if (bm_attr(&mb, BLOBMSG_TYPE_INT32, "source", &be, 4) != 0)
		return 0;
	hdr = htobe32((uint32_t)mb.len + 4);
	memcpy(b, &hdr, 4);
	return mb.len + 4;
}

static int selftest(void)
{
	static uint8_t buf[16384];
	uint8_t f[2048];
	size_t len = 0, n;
	int fails = 0, dn;

	memset(&st, 0, sizeof(st));
	n = mk_frame(f, sizeof(f), 1700000000123ULL, 7, 0x1e, 1, "selftest one");
	if (!n)
		return 3;
	memcpy(buf + len, f, n);
	len += n;
	memset(buf + len, 0x5a, 9);	/* garbage between records */
	len += 9;
	n = mk_frame(f, sizeof(f), 1700000000456ULL, 8, 0x1e, 0, "selftest two");
	memcpy(buf + len, f, n);
	len += n;
	n = mk_frame(f, sizeof(f), 1700000000789ULL, 9, 0x1e, 0, "truncated tail");
	memcpy(buf + len, f, n - 3);	/* partial record at EOF */
	len += n - 3;

	dn = open("/dev/null", O_WRONLY);
	if (dn >= 0)
		out_fd = dn;
	(void)consume_records(buf, len, 0, NULL, 1);
	if (dn >= 0)
		close(dn);

	if (st.frames < 2) {
		printf("selftest: frames=%llu (expected >=2)\n", st.frames);
		fails++;
	}
	if (st.bad_frames == 0) {
		printf("selftest: bad_frames=0 (expected >0)\n");
		fails++;
	}
	if (st.resyncs == 0) {
		printf("selftest: resyncs=0 (expected >0)\n");
		fails++;
	}
	if (st.dropped_bytes == 0) {
		printf("selftest: dropped_bytes=0 (expected >0)\n");
		fails++;
	}
	printf("logc %s selftest: %s frames=%llu bad_frames=%llu resyncs=%llu dropped=%llu\n",
	       LOGC_VERSION, fails ? "FAIL" : "PASS", st.frames, st.bad_frames,
	       st.resyncs, st.dropped_bytes);
	return fails ? 1 : 0;
}

static void usage(FILE *f)
{
	fprintf(f,
		"Usage: logc [options]\n"
		"  -l N        only the last N records\n"
		"  -f          follow (stream, no oneshot)\n"
		"  -F FILE     append to FILE instead of stdout\n"
		"  -S KB       rotate FILE above KB kilobytes\n"
		"  -t          prepend [epoch.millis]\n"
		"  -e REGEX    only records whose msg matches REGEX\n"
		"  -s PATH     ubus socket (default /var/run/ubus/ubus.sock)\n"
		"  -d          debug to stderr\n"
		"  --stats-file FILE   write counters (key=value)\n"
		"  --stdin     parse raw records from stdin (offline test)\n"
		"  --dump-raw FILE     keep raw stream bytes (capped) for replay\n"
		"  --raw-max BYTES     cap for --dump-raw (default 8388608)\n"
		"  --selftest  parser selftest on synthetic streams\n"
		"  -V          version\n");
}

int main(int argc, char **argv)
{
	const char *sock_path = "/var/run/ubus/ubus.sock";
	const char *regex_str = NULL;
	unsigned int lines = 0;
	int follow = 0, with_ts = 0, use_stdin = 0, do_selftest = 0;
	int ubus_fd = -1, stream_fd = -1;
	uint32_t objid = 0;
	regex_t re, *re_p = NULL;
	int ch, rc = 1;

	signal(SIGPIPE, SIG_IGN);
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	install_crash_handler();
	init_timezone();

	while (1) {
		static const struct option long_opts[] = {
			{ "stdin", no_argument, NULL, 1000 },
			{ "stats-file", required_argument, NULL, 1001 },
			{ "dump-raw", required_argument, NULL, 1002 },
			{ "raw-max", required_argument, NULL, 1003 },
			{ "selftest", no_argument, NULL, 1004 },
			{ NULL, 0, NULL, 0 },
		};
		int lidx = 0;

		ch = getopt_long(argc, argv, "l:fF:S:te:s:dV",
				 long_opts, &lidx);
		if (ch == -1)
			break;
		switch (ch) {
		case 'l':
			lines = (unsigned int)strtoul(optarg, NULL, 10);
			break;
		case 'f':
			follow = 1;
			break;
		case 'F':
			out_path = optarg;
			break;
		case 'S':
			out_limit = strtol(optarg, NULL, 10) * 1024L;
			if (out_limit < 0)
				out_limit = 0;
			break;
		case 't':
			with_ts = 1;
			break;
		case 'e':
			regex_str = optarg;
			break;
		case 's':
			sock_path = optarg;
			break;
		case 'd':
			debug = 1;
			break;
		case 'V':
			printf("logc %s\n", LOGC_VERSION);
			return 0;
		case 1000:
			use_stdin = 1;
			break;
		case 1001:
			stats_file = optarg;
			break;
		case 1002:
			raw_path = optarg;
			break;
		case 1003:
			raw_max = strtoull(optarg, NULL, 10);
			break;
		case 1004:
			do_selftest = 1;
			break;
		default:
			usage(stderr);
			return 1;
		}
	}
	if (optind < argc) {
		fprintf(stderr, "logc: unexpected argument %s\n", argv[optind]);
		return 1;
	}

	if (do_selftest)
		return selftest();

	if (regex_str) {
		if (regcomp(&re, regex_str, REG_EXTENDED | REG_NOSUB) != 0) {
			fprintf(stderr, "logc: bad regex\n");
			return 1;
		}
		re_p = &re;
	}

	if (open_output() != 0)
		return 1;

	if (use_stdin) {
		rc = read_stream_fd(STDIN_FILENO, with_ts, re_p, 1) == 0 ? 0 : 1;
		goto out;
	}

	ubus_fd = connect_ubus(sock_path);
	if (ubus_fd < 0 && !strcmp(sock_path, "/var/run/ubus/ubus.sock")) {
		ubus_fd = connect_ubus("/var/run/ubus.sock");
	}
	if (ubus_fd < 0) {
		fprintf(stderr, "logc: cannot connect to ubus (%s): %s\n",
			sock_path, strerror(errno));
		goto out;
	}
	if (ubus_hello(ubus_fd) != 0) {
		fprintf(stderr, "logc: bad ubus hello\n");
		goto out;
	}
	if (ubus_lookup(ubus_fd, "log", &objid) != 0) {
		fprintf(stderr, "logc: ubus object 'log' not found\n");
		goto out;
	}
	if (ubus_open_log_stream(ubus_fd, objid, follow, lines, &stream_fd) != 0) {
		fprintf(stderr, "logc: logd refused the stream request\n");
		goto out;
	}

	rc = read_stream_fd(stream_fd, with_ts, re_p, follow) == 0 ? 0 : 1;

out:
	if (stream_fd >= 0)
		close(stream_fd);
	if (ubus_fd >= 0)
		close(ubus_fd);
	if (out_fd != STDOUT_FILENO)
		close(out_fd);
	if (raw_fp)
		fclose(raw_fp);
	if (re_p)
		regfree(re_p);
	write_stats();
	if (debug)
		fprintf(stderr, "logc: frames=%llu bytes=%llu bad=%llu resync=%llu "
			"dropped=%llu bad_time=%llu bad_attrs=%llu filtered=%llu\n",
			st.frames, st.bytes, st.bad_frames, st.resyncs,
			st.dropped_bytes, st.bad_time, st.bad_attrs, st.filtered);
	return rc;
}
