/* tcpok.c v1.0 -- connect-only liveness probe (exit 0 = connect OK).
 *
 * Usage: tcpok <ip> <port> [timeout_ms, default 2000]
 *
 * Why (avail audit round): the heuristic availability watcher needs a
 * 2s-cadence "is the listener accepting" fact.  busybox wget does a full
 * GET (v3httpd logs one line per request -> 43k lines/day at 2s cadence);
 * busybox nc has no -z and its EOF/timeout exit codes are ambiguous under
 * `timeout(1)`.  A bare TCP connect is silent on the server side (v3httpd's
 * handle_conn returns before logging when the peer sends nothing), so this
 * probe is log-free at any cadence.
 *
 * Non-blocking connect + poll(POLLOUT) + SO_ERROR, per the house defensive
 * style.  Build: sh tools/build_tcpok.sh (zig cc aarch64-linux-musl static).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: tcpok <ip> <port> [timeout_ms]\n"); return 2; }
    int port = atoi(argv[2]);
    int tmo = argc > 3 ? atoi(argv[3]) : 2000;
    if (port <= 0 || port > 65535 || tmo <= 0) return 2;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, argv[1], &a.sin_addr) != 1) return 2;

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return 1;
    int fl = fcntl(s, F_GETFL, 0);
    if (fl >= 0) fcntl(s, F_SETFL, fl | O_NONBLOCK);
    int r = connect(s, (struct sockaddr *)&a, sizeof a);
    if (r < 0 && errno != EINPROGRESS) { close(s); return 1; }
    if (r < 0) {
        struct pollfd p = { s, POLLOUT, 0 };
        if (poll(&p, 1, tmo) <= 0) { close(s); return 1; }
        int err = 0; socklen_t el = sizeof err;
        if (getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &el) < 0 || err) { close(s); return 1; }
    }
    close(s);
    return 0;
}
