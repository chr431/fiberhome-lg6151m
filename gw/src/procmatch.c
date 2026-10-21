/*
 * procmatch.c -- static pidof(1)/pgrep(1) replacement (busybox-compatible subset)
 *
 * Why: the 2026-10-21 crash census has pidof at ~2.7 crashes/day and pgrep is
 * used in 65 places by the supervision/lock code.  Both are busybox applets on
 * the static musl whose printf/stdio va_list path is the known family defect
 * (docs/SIGSEGV_ANALYSIS.md section 12); these applets print PIDs, so they sit
 * on the same surface.  This tool scans /proc and prints with bounded manual
 * formatting: no printf family, no locale, no dynamic arrays.
 *
 * Modes (argv[0] basename, or first argument):
 *   pidof [-s] NAME...        space-separated PIDs, exit 0 if any found
 *                             (matches comm or the basename of argv[0])
 *   pgrep [-f] [-x] [-F] PAT  one PID per line, exit 0 if any found
 *                             -f: match the full command line (args joined by
 *                                 spaces) instead of comm
 *                             -x: exact whole-string match
 *                             -F: fixed string (no ERE)
 *
 * Self is always excluded (the classic pgrep self-match trap).
 *
 * v1.0 -- initial.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <regex.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PROCMATCH_VERSION "1.0"
#define MAX_CMD 8192

long write(int, const void *, unsigned long);
void _exit(int);

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

static size_t put_str(char *b, size_t n, size_t cap, const char *s)
{
	size_t l = strlen(s);

	if (l > cap - n)
		l = cap - n;
	memcpy(b + n, s, l);
	if (n + l < cap)
		b[n + l] = 0;
	return n + l;
}

static size_t put_u(char *b, size_t n, size_t cap, unsigned long v)
{
	char t[24];
	size_t k = 0;

	do {
		t[k++] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	while (k && n < cap)
		b[n++] = t[--k];
	return n;
}

static ssize_t read_file(const char *path, char *buf, size_t cap)
{
	int fd = open(path, O_RDONLY);
	ssize_t n, got = 0;

	if (fd < 0)
		return -1;
	while (got < (ssize_t)cap - 1) {
		n = read(fd, buf + got, (size_t)(cap - 1 - (size_t)got));
		if (n < 0) {
			if (errno == EINTR)
				continue;
			close(fd);
			return -1;
		}
		if (n == 0)
			break;
		got += n;
	}
	close(fd);
	buf[got] = 0;
	return got;
}

static int parse_pid(const char *name)
{
	unsigned long v = 0;
	const char *p = name;

	if (!*p)
		return -1;
	for (; *p; p++) {
		if (*p < '0' || *p > '9')
			return -1;
		v = v * 10 + (unsigned long)(*p - '0');
		if (v > 0x7fffffffUL)
			return -1;
	}
	return (int)v;
}

static const char *base_name(const char *p)
{
	const char *s = strrchr(p, '/');

	return s ? s + 1 : p;
}

/* Join a NUL-separated cmdline into spaces; returns length. */
static size_t join_cmdline(char *dst, size_t cap, const char *src, ssize_t len)
{
	size_t o = 0;
	ssize_t i = 0;

	while (i < len && o + 1 < cap) {
		if (src[i] == 0) {
			if (i + 1 < len)
				dst[o++] = ' ';
			i++;
			continue;
		}
		dst[o++] = src[i++];
	}
	dst[o] = 0;
	return o;
}

/* ---- pidof ------------------------------------------------------------- */

static int do_pidof(int argc, char **argv)
{
	char path[64], comm[256], cmd[MAX_CMD], out[4096];
	size_t on = 0;
	int found = 0, first = 1, i;
	DIR *d;
	struct dirent *de;

	if (argc < 1) {
		write_all(2, "usage: pidof [-s] NAME...\n", 26);
		return 2;
	}
	d = opendir("/proc");
	if (!d)
		return 1;
	while ((de = readdir(d)) != NULL) {
		int pid = parse_pid(de->d_name);
		const char *cn, *an = NULL;

		if (pid <= 0 || pid == (int)getpid())
			continue;
		{
			size_t pn = 0;

			pn = put_str(path, 0, sizeof(path), "/proc/");
			pn = put_str(path, pn, sizeof(path), de->d_name);
			pn = put_str(path, pn, sizeof(path), "/comm");
			if (read_file(path, comm, sizeof(comm)) <= 0)
				continue;
			{
				size_t l = strlen(comm);

				while (l && (comm[l - 1] == '\n' || comm[l - 1] == ' '))
					comm[--l] = 0;
			}
			pn = 0;
			pn = put_str(path, 0, sizeof(path), "/proc/");
			pn = put_str(path, pn, sizeof(path), de->d_name);
			pn = put_str(path, pn, sizeof(path), "/cmdline");
			if (read_file(path, cmd, sizeof(cmd)) > 0 && cmd[0])
				an = base_name(cmd);
			cn = comm;
			for (i = 0; i < argc; i++) {
				if (!strcmp(argv[i], cn) || (an && !strcmp(argv[i], an))) {
					found = 1;
					if (on + 32 < sizeof(out)) {
						if (!first && on < sizeof(out))
							out[on++] = ' ';
						on = put_u(out, on, sizeof(out), (unsigned long)pid);
						first = 0;
					}
					break;
				}
			}
		}
	}
	closedir(d);
	if (found && on < sizeof(out))
		out[on++] = '\n';
	if (found)
		write_all(1, out, on);
	return found ? 0 : 1;
}

/* ---- pgrep ------------------------------------------------------------- */

static int do_pgrep(int argc, char **argv)
{
	int full = 0, exact = 0, fixed = 0, i = 0, found = 0;
	const char *pat;
	regex_t re;
	int have_re = 0;
	DIR *d;
	struct dirent *de;
	char path[64], comm[256], cmd[MAX_CMD], line[64];
	size_t ln;

	while (i < argc && argv[i][0] == '-' && argv[i][1]) {
		if (!strcmp(argv[i], "-f"))
			full = 1;
		else if (!strcmp(argv[i], "-x"))
			exact = 1;
		else if (!strcmp(argv[i], "-F"))
			fixed = 1;
		else if (!strcmp(argv[i], "--"))
			{ i++; break; }
		else
			return 2;
		i++;
	}
	if (i >= argc)
		return 2;
	pat = argv[i];
	if (!exact && !fixed) {
		if (regcomp(&re, pat, REG_EXTENDED | REG_NOSUB) != 0)
			return 2;
		have_re = 1;
	}
	d = opendir("/proc");
	if (!d) {
		if (have_re)
			regfree(&re);
		return 1;
	}
	while ((de = readdir(d)) != NULL) {
		int pid = parse_pid(de->d_name), match = 0;
		char target[MAX_CMD];
		const char *tp;

		if (pid <= 0 || pid == (int)getpid())
			continue;
		{
			size_t pn = 0;

			pn = put_str(path, 0, sizeof(path), "/proc/");
			pn = put_str(path, pn, sizeof(path), de->d_name);
			pn = put_str(path, pn, sizeof(path), "/comm");
		}
		if (read_file(path, comm, sizeof(comm)) <= 0)
			continue;
		{
			size_t l = strlen(comm);

			while (l && comm[l - 1] == '\n')
				comm[--l] = 0;
		}
		if (full) {
			ssize_t n;

			{
				size_t pn = 0;

				pn = put_str(path, 0, sizeof(path), "/proc/");
				pn = put_str(path, pn, sizeof(path), de->d_name);
				pn = put_str(path, pn, sizeof(path), "/cmdline");
			}
			n = read_file(path, cmd, sizeof(cmd));
			if (n <= 0)
				continue;
			join_cmdline(target, sizeof(target), cmd, n);
			tp = target;
		} else {
			tp = comm;
		}
		if (!*tp)
			continue;
		if (exact)
			match = !strcmp(tp, pat);
		else if (fixed)
			match = strstr(tp, pat) != NULL;
		else
			match = regexec(&re, tp, 0, NULL, 0) == 0;
		if (match) {
			ln = put_u(line, 0, sizeof(line), (unsigned long)pid);
			if (ln < sizeof(line))
				line[ln++] = '\n';
			write_all(1, line, ln);
			found = 1;
		}
	}
	closedir(d);
	if (have_re)
		regfree(&re);
	return found ? 0 : 1;
}

int main(int argc, char **argv)
{
	const char *prog = base_name(argv[0]);

	if (!strcmp(prog, "pidof"))
		return do_pidof(argc - 1, argv + 1);
	if (!strcmp(prog, "pgrep"))
		return do_pgrep(argc - 1, argv + 1);
	if (argc >= 2 && !strcmp(argv[1], "pidof"))
		return do_pidof(argc - 2, argv + 2);
	if (argc >= 2 && !strcmp(argv[1], "pgrep"))
		return do_pgrep(argc - 2, argv + 2);
	if (argc == 2 && !strcmp(argv[1], "-V")) {
		const char v[] = "procmatch " PROCMATCH_VERSION "\n";

		return write_all(1, v, sizeof(v) - 1) == 0 ? 0 : 1;
	}
	write_all(2, "usage: procmatch pidof|pgrep ...\n", 33);
	return 2;
}
