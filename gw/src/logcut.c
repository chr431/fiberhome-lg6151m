/*
 * logcut.c -- print the lines that follow the LAST exact match of an anchor.
 *
 * Why: log_keeper's delta() used busybox awk (index/length + a B[] array).
 * A 2026-10-21 core showed the static busybox 1.36.1 awk dereferencing NULL
 * in its array-free path at exit:
 *
 *     pc=0x491ab8  ldr w0,[x19,#4]   x19=0   si_addr=4
 *     caller 0x4932d0: bl <free helper>  with the unchecked return of
 *                      [node+0x18]
 *
 * On-device A/B (same 4MB syslog, same anchor, 400 runs each):
 *   - anchor at EOF (no array created):            0 crashes
 *   - anchor at EOF + split("", B) (empty array):  4 crashes
 *   - mid-file anchor (B filled with ~18k lines):  ~0.7% crashes
 * i.e. ANY runtime array in this awk build can kill the process at exit.
 * The array cannot be "used carefully"; it has to go.
 *
 * This tool does the same job with a single streaming pass and one growable
 * line buffer: no arrays, no printf, no locale.  It records the byte offset
 * just past the last line equal to the anchor, then copies the tail of the
 * file to stdout.
 *
 * Semantics match the awk it replaces (and are stricter): the anchor is
 * compared as raw bytes (awk -v interpreted backslash escapes), a line is the
 * bytes between newlines without the newline, and the last match wins.
 *
 * CLI:
 *   logcut --after-last ANCHOR FILE   print everything after the last match
 *   logcut --check ANCHOR FILE        exit 0 if the anchor exists, 1 if not
 *   logcut --selftest                 built-in parser/copy checks
 *   logcut -V                         version
 * Exit: 0 ok, 1 anchor missing / IO error, 2 usage.
 *
 * v1.0 -- initial; replaces busybox awk in gw/log_keeper.sh delta().
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LOGCUT_VERSION "1.0"
#define IOBUF 65536u
#define LINE_INIT 4096u
#define LINE_MAX_CAP (1u << 20)

static int write_all(int fd, const void *p, size_t n)
{
	const char *b = p;

	while (n) {
		ssize_t w = write(fd, b, n);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (w == 0)
			return -1;
		b += w;
		n -= (size_t)w;
	}
	return 0;
}

static void say(const char *s)
{
	(void)write_all(2, s, strlen(s));
	(void)write_all(2, "\n", 1);
}

/* Scan the whole file; on success store the offset just past the last line
 * equal to the anchor.  Returns 0 on success (found), 1 if not found, -1 on
 * an IO/allocation error. */
static int find_after_last(int fd, const char *anchor, size_t alen, off_t *after)
{
	char *iob = malloc(IOBUF);
	char *line = malloc(LINE_INIT);
	size_t cap = LINE_INIT, len = 0;
	int truncated = 0, found = 0;
	off_t pos = 0;

	if (!iob || !line) {
		free(iob);
		free(line);
		return -1;
	}
	for (;;) {
		ssize_t n = read(fd, iob, IOBUF);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			free(iob);
			free(line);
			return -1;
		}
		if (n == 0)
			break;
		for (ssize_t i = 0; i < n; i++) {
			char c = iob[i];

			if (c == '\n') {
				if (!truncated && len == alen &&
				    memcmp(line, anchor, alen) == 0) {
					found = 1;
					*after = pos + i + 1;
				}
				len = 0;
				truncated = 0;
				continue;
			}
			if (truncated)
				continue;
			if (len == cap) {
				size_t ncap = cap * 2;
				char *nl;

				if (ncap > LINE_MAX_CAP) {
					truncated = 1;	/* too long: never matches */
					continue;
				}
				nl = realloc(line, ncap);
				if (!nl) {
					free(iob);
					free(line);
					return -1;
				}
				line = nl;
				cap = ncap;
			}
			line[len++] = c;
		}
		pos += n;
	}
	/* last line without a trailing newline */
	if (!truncated && len == alen && memcmp(line, anchor, alen) == 0) {
		found = 1;
		*after = pos;	/* nothing follows it */
	}
	free(iob);
	free(line);
	return found ? 0 : 1;
}

static int copy_tail(int fd, off_t after)
{
	char *iob = malloc(IOBUF);
	int rc = 0;

	if (!iob)
		return -1;
	if (lseek(fd, after, SEEK_SET) < 0) {
		free(iob);
		return -1;
	}
	for (;;) {
		ssize_t n = read(fd, iob, IOBUF);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			rc = -1;
			break;
		}
		if (n == 0)
			break;
		if (write_all(1, iob, (size_t)n) != 0) {
			rc = -1;
			break;
		}
	}
	free(iob);
	return rc;
}

static int do_file(const char *anchor, const char *path, int check_only)
{
	size_t alen = strlen(anchor);
	off_t after = 0;
	int fd, rc;

	if (!alen) {
		say("logcut: empty anchor");
		return 2;
	}
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		say("logcut: cannot open input");
		return 1;
	}
	rc = find_after_last(fd, anchor, alen, &after);
	if (rc != 0) {
		close(fd);
		return rc == 1 ? 1 : 1;
	}
	if (check_only) {
		close(fd);
		return 0;
	}
	rc = copy_tail(fd, after);
	close(fd);
	return rc == 0 ? 0 : 1;
}

static int selftest(void)
{
	static const char data[] =
		"alpha\nanchor\nbeta\nANCHOR\nanchor\ngamma\n";
	static const char want[] = "gamma\n";
	static const char noeol[] = "one\ntwo\nanchor";
	char buf[256];
	const char *path = "/tmp/logcut.selftest";
	int fd, rc = 0, n;
	off_t after = 0;

	fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
	if (fd < 0) {
		say("logcut selftest: cannot create temp");
		return 1;
	}
	if (write_all(fd, data, sizeof(data) - 1) != 0) {
		close(fd);
		return 1;
	}
	close(fd);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return 1;
	if (find_after_last(fd, "anchor", 6, &after) != 0 ||
	    lseek(fd, after, SEEK_SET) < 0) {
		say("logcut selftest: find failed");
		rc = 1;
	} else {
		n = (int)read(fd, buf, sizeof(buf));
		if (n != (int)(sizeof(want) - 1) || memcmp(buf, want, (size_t)n) != 0) {
			say("logcut selftest: tail mismatch");
			rc = 1;
		}
	}
	close(fd);
	/* no trailing newline: anchor is the last line -> empty tail */
	fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
	if (fd >= 0) {
		(void)write_all(fd, noeol, sizeof(noeol) - 1);
		close(fd);
		fd = open(path, O_RDONLY);
		if (fd >= 0) {
			if (find_after_last(fd, "anchor", 6, &after) != 0) {
				say("logcut selftest: eof-anchor failed");
				rc = 1;
			}
			close(fd);
		}
	}
	unlink(path);
	if (rc == 0) {
		const char ok[] = "logcut " LOGCUT_VERSION " selftest: PASS\n";

		(void)write_all(1, ok, sizeof(ok) - 1);
	}
	return rc;
}

int main(int argc, char **argv)
{
	if (argc == 2 && !strcmp(argv[1], "-V")) {
		const char v[] = "logcut " LOGCUT_VERSION "\n";

		return write_all(1, v, sizeof(v) - 1) == 0 ? 0 : 1;
	}
	if (argc == 2 && !strcmp(argv[1], "--selftest"))
		return selftest();
	if (argc == 4 && !strcmp(argv[1], "--after-last"))
		return do_file(argv[2], argv[3], 0);
	if (argc == 4 && !strcmp(argv[1], "--check"))
		return do_file(argv[2], argv[3], 1);
	say("usage: logcut --after-last ANCHOR FILE | --check ANCHOR FILE | --selftest | -V");
	return 2;
}
