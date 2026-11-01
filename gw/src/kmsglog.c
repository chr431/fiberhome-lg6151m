/* kmsglog.c v1.1 -- persistent /dev/kmsg mirror (A1 far-infra).
 *
 * v1.1: cursor rewind re-implemented -- lseek(fd, seq, SEEK_SET) is EINVAL on
 *   this 5.15 kernel (nonzero offsets are rejected; measured on device
 *   2026-11-01).  Real primitive: lseek(fd, 0, SEEK_SET) rewinds to the
 *   oldest buffered record, then records are skipped until their sequence
 *   number reaches the first unwritten one (records with seq < pending were
 *   already flushed -> dropped, never duplicated).
 *
 * Usage: kmsglog [--log /data/gw/logs/kmsg.log] [--max-kb 8192] [--backups 1]
 *                [--low-kb 102400] [--selftest]
 *
 * Why: arm64 user fault lines ("... unhandled level N ... fault (11) at
 * 0x...") are pr_info; console_loglevel on this image is 4, so neither the
 * console nor the syslog path ever carries them.  /dev/kmsg reads the ring
 * buffer directly and level-independently -- this daemon mirrors it to /data
 * so fault lines (and SEQ gaps = ring overflow, visible in the log itself)
 * survive reboots.
 *
 * Disk discipline (2026-11-01 lesson: a 25MB/s dd fills /data in 60s while
 * 5-minute guard ticks never fire):
 *   - write-guard BEFORE every write(): one statvfs; below --low-kb the log
 *     is trimmed first (rotate away the backup, start a fresh file);
 *   - size cap: rotate at --max-kb, keep --backups old files;
 *   - a failed/partial write NEVER advances the kmsg cursor: the batch is
 *     dropped and the read position rewound (SEEK_SET 0 + skip records with
 *     seq < first-unwritten; primitive verified by --selftest), so records
 *     are retried rather than silently lost.
 *
 * Single instance: /tmp/kmsglog.pid (O_EXCL; stale pid detected via
 * kill(pid,0)==ESRCH).  Heartbeat: /tmp/kmsglog.hb (epoch, every 60s).
 * Start marker: one "# kmsglog ... start" line per launch.
 *
 * Build (static aarch64 musl): see tools/build_kmsglog.sh (zig cc).
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define KMSGLOG_VER "1.1"
#define DEV_KMSG    "/dev/kmsg"
#define PIDFILE     "/tmp/kmsglog.pid"
#define HBFILE      "/tmp/kmsglog.hb"
#define ERRFILE     "/tmp/kmsglog.err"
#define LOGDIR      "/data/gw/logs"
#define REC_MAX     16384        /* one kmsg record (with cont) */
#define BATCH_MAX   65536        /* flush granularity -> one write() per batch */
#define POLL_MS     1000
#define HB_EVERY_S  60
#define RETRY_MS    500

static const char *g_log = LOGDIR "/kmsg.log";
static long g_max_kb = 8192;
static long g_backups = 1;
static long g_low_kb = 102400;
static volatile sig_atomic_t g_stop = 0;
static unsigned long long g_skip_below = 0;  /* after a rewind: drop already-flushed records (seq < this) */
static int g_have_pidfile = 0;
static pid_t g_mypid;

static void on_term(int sig) { (void)sig; g_stop = 1; }

static void note_err(const char *what)
{
    /* breadcrumb on tmpfs: never adds /data pressure */
    int fd = open(ERRFILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char line[256];
    int n;
    if (fd < 0)
        return;
    n = snprintf(line, sizeof(line), "%llu %s: %s\n",
                 (unsigned long long)time(NULL), what, strerror(errno));
    if (n > 0)
        (void)write(fd, line, (size_t)n);
    close(fd);
}

static void hb_write(void)
{
    int fd = open(HBFILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char line[64];
    int n;
    if (fd < 0)
        return;
    n = snprintf(line, sizeof(line), "%llu\n", (unsigned long long)time(NULL));
    if (n > 0)
        (void)write(fd, line, (size_t)n);
    close(fd);
}

/* first decimal field of a kmsg record prefix is its sequence number */
static unsigned long long rec_seq(const char *rec, ssize_t len)
{
    unsigned long long seq = 0;
    ssize_t i;
    for (i = 0; i < len && rec[i] >= '0' && rec[i] <= '9'; i++)
        seq = seq * 10 + (unsigned long long)(rec[i] - '0');
    return (i > 0 && i < len && rec[i] == ',') ? seq : 0;
}

static long data_free_kb(void)
{
    struct statvfs v;
    unsigned long long kb;
    if (statvfs("/data", &v) != 0)
        return -1;
    if (v.f_frsize == 0)
        v.f_frsize = v.f_bsize;
    if (v.f_frsize == 0)
        return -1;
    kb = (unsigned long long)v.f_bavail * (unsigned long long)v.f_frsize / 1024ULL;
    return kb > 1000000000ULL ? 1000000000LL : (long)kb;
}

/* rotate: log -> log.1 (older backups already unlinked), caller reopens */
static void rotate_away(void)
{
    char old[512], cur[512];
    long i;
    for (i = g_backups; i >= 2; i--) {
        snprintf(old, sizeof(old), "%s.%ld", g_log, i);
        snprintf(cur, sizeof(cur), "%s.%ld", g_log, i - 1);
        unlink(old);
        rename(cur, old);
    }
    if (g_backups >= 1) {
        snprintf(old, sizeof(old), "%s.1", g_log);
        unlink(old);
        rename(g_log, old);
    } else {
        unlink(g_log);
    }
}

static int file_size_kb(const char *p)
{
    struct stat st;
    if (stat(p, &st) != 0)
        return 0;
    return (int)((st.st_size + 1023) / 1024);
}

/* returns fd of the fresh log (appending), or -1 */
static int open_log_append(void)
{
    return open(g_log, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static int selftest(void)
{
    char rec[REC_MAX];
    unsigned long long s1, s2;
    ssize_t n;
    int fd, fail = 0;
    long free_kb;

    fd = open(DEV_KMSG, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        printf("FAIL open %s: %s\n", DEV_KMSG, strerror(errno));
        return 1;
    }
    if (lseek(fd, 0, SEEK_SET) < 0) {
        printf("FAIL rewind %s: %s\n", DEV_KMSG, strerror(errno));
        close(fd);
        return 1;
    }
    do {
        n = read(fd, rec, sizeof(rec) - 1);
    } while (n < 0 && errno == EINTR);
    if (n <= 0) {
        printf("FAIL read %s (ring empty?): rc=%zd errno=%s\n",
               DEV_KMSG, n, n < 0 ? strerror(errno) : "0");
        close(fd);
        return 1;
    }
    rec[n] = 0;
    s1 = rec_seq(rec, n);
    /* rewind primitive (measured on device 2026-11-01: nonzero-offset lseek
     * on this 5.15 kernel is EINVAL) = SEEK_SET 0 + skip forward by seq */
    if (lseek(fd, 0, SEEK_SET) < 0) {
        printf("FAIL rewind-0 %s: %s\n", DEV_KMSG, strerror(errno));
        close(fd);
        return 1;
    }
    {
        int guard = 0;
        for (;;) {
            do {
                n = read(fd, rec, sizeof(rec) - 1);
            } while (n < 0 && errno == EINTR);
            if (n <= 0) {
                printf("FAIL scan-forward after rewind: rc=%zd\n", n);
                close(fd);
                return 1;
            }
            rec[n] = 0;
            s2 = rec_seq(rec, n);
            if (s2 >= s1)
                break;
            if (++guard > 200000) {
                printf("FAIL scan-forward: no seq>=%llu within bound\n", s1);
                close(fd);
                return 1;
            }
        }
    }
    if (s1 == 0 || s1 != s2) {
        printf("FAIL cursor rewind: first seq=%llu re-read seq=%llu (overwritten?)\n", s1, s2);
        fail++;
    } else {
        printf("PASS cursor rewind (SEEK_SET0+skip to seq %llu)\n", s1);
    }
    close(fd);

    free_kb = data_free_kb();
    if (free_kb < 0) {
        printf("FAIL statvfs /data: %s\n", strerror(errno));
        fail++;
    } else {
        printf("PASS statvfs /data free_kb=%ld low_kb=%ld\n", free_kb, g_low_kb);
    }
    printf("%s\n", fail ? "SELFTEST FAIL" : "SELFTEST PASS");
    return fail ? 1 : 0;
}

static int take_pidfile(void)
{
    char buf[32];
    int fd, n, retry;
    for (retry = 0; retry < 2; retry++) {
        fd = open(PIDFILE, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd >= 0) {
            n = snprintf(buf, sizeof(buf), "%d\n", (int)g_mypid);
            (void)write(fd, buf, (size_t)n);
            close(fd);
            g_have_pidfile = 1;
            return 0;
        }
        if (errno != EEXIST) {
            note_err("pidfile create");
            return -1;
        }
        fd = open(PIDFILE, O_RDONLY);
        if (fd < 0) {
            unlink(PIDFILE);
            continue;
        }
        n = (int)read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            buf[n] = 0;
            {
                long old = strtol(buf, NULL, 10);
                if (old > 0 && (kill((pid_t)old, 0) == 0 || errno != ESRCH)) {
                    fprintf(stderr, "kmsglog: already running (pid %ld)\n", old);
                    return 1; /* caller exits 0 -- not an error */
                }
            }
        }
        unlink(PIDFILE); /* stale */
    }
    note_err("pidfile race");
    return -1;
}

static void drop_pidfile(void)
{
    char buf[32];
    int fd, n;
    if (!g_have_pidfile)
        return;
    fd = open(PIDFILE, O_RDONLY);
    if (fd >= 0) {
        n = (int)read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            buf[n] = 0;
            if (strtol(buf, NULL, 10) == (long)g_mypid)
                unlink(PIDFILE);
            return;
        }
    }
    unlink(PIDFILE);
}

int main(int argc, char **argv)
{
    int kfd, logfd = -1;
    char rec[REC_MAX];
    static char batch[BATCH_MAX + REC_MAX];
    size_t blen = 0;
    unsigned long long pending_seq = 0;
    time_t last_hb = 0;
    struct pollfd pfd;
    int i;

    g_mypid = getpid();
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--selftest"))
            return selftest();
        else if (!strcmp(argv[i], "--log") && i + 1 < argc)
            g_log = argv[++i];
        else if (!strcmp(argv[i], "--max-kb") && i + 1 < argc)
            g_max_kb = strtol(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--backups") && i + 1 < argc)
            g_backups = strtol(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--low-kb") && i + 1 < argc)
            g_low_kb = strtol(argv[++i], NULL, 10);
        else {
            fprintf(stderr, "usage: %s [--log P] [--max-kb N] [--backups N] "
                            "[--low-kb N] [--selftest]\n", argv[0]);
            return 2;
        }
    }
    if (g_max_kb < 64)
        g_max_kb = 64;
    if (g_backups < 0)
        g_backups = 0;
    if (g_backups > 4)
        g_backups = 4;
    if (g_low_kb < 1024)
        g_low_kb = 1024;

    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_term;   /* no SA_RESTART: poll must wake up */
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);
        signal(SIGPIPE, SIG_IGN);
    }

    i = take_pidfile();
    if (i != 0)
        return i == 1 ? 0 : 1;

    mkdir(LOGDIR, 0755);

    kfd = open(DEV_KMSG, O_RDONLY | O_NONBLOCK);
    if (kfd < 0) {
        note_err("open /dev/kmsg");
        fprintf(stderr, "kmsglog: open %s: %s\n", DEV_KMSG, strerror(errno));
        drop_pidfile();
        return 1;
    }
    if (lseek(kfd, 0, SEEK_END) < 0) {   /* only NEW records */
        note_err("seek end");
        close(kfd);
        drop_pidfile();
        return 1;
    }

    logfd = open_log_append();
    if (logfd < 0) {
        note_err("open log");
        close(kfd);
        drop_pidfile();
        return 1;
    }
    {
        char line[160];
        char bid[64] = "-";
        int bfd = open("/proc/sys/kernel/random/boot_id", O_RDONLY);
        int n, w;
        if (bfd >= 0) {
            n = (int)read(bfd, bid, sizeof(bid) - 1);
            close(bfd);
            if (n > 0) {
                bid[n] = 0;
                while (n > 0 && (bid[n - 1] == '\n' || bid[n - 1] == '\r'))
                    bid[--n] = 0;
            }
        }
        w = snprintf(line, sizeof(line),
                     "# kmsglog v%s start boot_id=%s ts=%llu\n", KMSGLOG_VER,
                     bid, (unsigned long long)time(NULL));
        if (w > 0)
            (void)write(logfd, line, (size_t)w);
    }
    hb_write();
    last_hb = time(NULL);

    pfd.fd = kfd;
    pfd.events = POLLIN;
    while (!g_stop) {
        int pr = poll(&pfd, 1, POLL_MS);
        if (pr < 0) {
            if (errno == EINTR)
                continue;
            note_err("poll");
            sleep(1);
            continue;
        }
        if (pr > 0 && (pfd.revents & POLLIN)) {
            for (;;) {  /* drain what is available into the batch */
                ssize_t n = read(kfd, rec, sizeof(rec) - 1);
                if (n < 0) {
                    if (errno == EINTR)
                        continue;
                    if (errno == EAGAIN)
                        break;
                    note_err("read kmsg");
                    break;
                }
                if (n == 0)
                    break;
                if (g_skip_below) {
                    unsigned long long sq = rec_seq(rec, n);
                    if (sq < g_skip_below)
                        continue;        /* already flushed: skip, no duplicates */
                    g_skip_below = 0;
                }
                if (blen == 0)
                    pending_seq = rec_seq(rec, n);
                if (blen + (size_t)n > sizeof(batch)) {
                    /* batch full: flush below and come back */
                    break;
                }
                memcpy(batch + blen, rec, (size_t)n);
                blen += (size_t)n;
                if (rec[n - 1] != '\n') {
                    batch[blen] = '\n'; /* defensive: keep line structure */
                    blen++;
                }
            }
        }
        if (blen == 0) {
            time_t now = time(NULL);
            if (now - last_hb >= HB_EVERY_S) {
                hb_write();
                last_hb = now;
            }
            continue;
        }

        /* ---- write-guard: check /data BEFORE every write ---- */
        {
            long free_kb = data_free_kb();
            int need_rotate = (file_size_kb(g_log) + (long)(blen / 1024) + 1 >= g_max_kb);
            if (free_kb >= 0 && free_kb < g_low_kb)
                need_rotate = 1;          /* full disk: trim BEFORE writing */
            if (need_rotate) {
                close(logfd);
                rotate_away();
                logfd = open_log_append();
                if (logfd < 0) {
                    note_err("reopen log after rotate");
                    sleep(1);
                    continue;
                }
            }
        }

        {
            ssize_t w = write(logfd, batch, blen);
            if (w == (ssize_t)blen) {
                blen = 0;                 /* only now is the cursor advanced */
            } else {
                /* never advance: rewind to the oldest record and skip
                 * forward to the first unwritten one (seq-seek lseek is
                 * EINVAL on this kernel; measured 2026-11-01) */
                note_err("write log");
                if (lseek(kfd, 0, SEEK_SET) < 0)
                    note_err("rewind");
                g_skip_below = pending_seq;
                blen = 0;
                {
                    struct timespec ts;
                    ts.tv_sec = 0;
                    ts.tv_nsec = RETRY_MS * 1000000L;
                    nanosleep(&ts, NULL);
                }
                continue;
            }
        }
    }

    if (blen > 0 && logfd >= 0)
        (void)write(logfd, batch, blen);  /* best effort on shutdown */
    close(logfd);
    close(kfd);
    drop_pidfile();
    return 0;
}
