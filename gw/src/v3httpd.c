/* v3httpd.c v2.6 (P2: 静态面拒绝 *.sh 下载(原 GET /api.sh 直出全部服务端逻辑);
 *   Host 头校验 — 非本机 IP 的 Host 一律 400, 根治 DNS rebinding 经受害者
 *   浏览器绕同源策略打 /api/* 的通路; 缺 Host 头的老客户端放行(仅校验存在者))
 * v2.5 (P1: 防慢连+并发上限) -- tiny HTTP server for the v3 gateway GUI (192.168.9.1:80).
 * zig cc -target aarch64-linux-musl tools/v3httpd.c -o v3httpd -O2
 *   (fully static: no FH libs; run directly)
 * Serves: GET  /            -> /data/gw/www/index.html
 *         GET  /api/<ep>    -> exec api.sh <ep> (JSON out; query via V3_QUERY)
 *         POST /api/<ep>    -> same + V3_BODY (form-encoded, <=24KB)
 *         GET  /<file>      -> /data/gw/www/<file> (path-sanitized)
 * v2.0 changes vs v1.0:
 *   - bind 192.168.9.1 ONLY (v1.0 INADDR_ANY exposed GUI to WAN side)
 *   - POST: Content-Length body -> env V3_BODY; method -> V3_METHOD
 *   - CGI via fork+execv (v1.0 popen command-string = shell injection hole)
 *   - endpoint whitelist [a-z0-9_] enforced in C before exec
 * v2.2: FH App API 透明隧道 — /fh_api/* 与 /api/tmp/* 双向转发到本机
 *   127.0.0.1:8080 (原厂 nginx/webs, 由 webs_revive.sh 拉起)。烽火终端
 *   App 只认 80 口; 我们的 /api/<ep> 端点名不含 "tmp/" 子路径, 无冲突。
 *   隧道按字节流中继(自然支持 POST body/keep-alive), 60s 活动超时。
 * Logs to /tmp/v3httpd.log (one line per request).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdarg.h>
#include <poll.h>
#include <errno.h>
#include <time.h>

static void handle_conn(int c, char *req, size_t reqsz);

#ifndef WWW_ROOT_PATH              /* 公开构建可 -DWWW_ROOT_PATH=/data/gw/www 覆盖(免引号) */
#define WWW_ROOT_PATH /data/gw/www
#endif
#define STR2(x) #x
#define STR(x) STR2(x)
#define WWW_ROOT STR(WWW_ROOT_PATH)
#define PORT 80
#define BIND_IP "192.168.9.1"
#define LOGF "/tmp/v3httpd.log"
#define BODY_MAX 24576

static const char *mime(const char *p)
{
    const char *e = strrchr(p, '.');
    if (!e) return "application/octet-stream";
    if (!strcmp(e, ".html")) return "text/html; charset=utf-8";
    if (!strcmp(e, ".js"))   return "application/javascript; charset=utf-8";
    if (!strcmp(e, ".css"))  return "text/css; charset=utf-8";
    if (!strcmp(e, ".json")) return "application/json; charset=utf-8";
    if (!strcmp(e, ".svg"))  return "image/svg+xml";
    if (!strcmp(e, ".png"))  return "image/png";
    if (!strcmp(e, ".ico"))  return "image/x-icon";
    return "application/octet-stream";
}

static void logline(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    FILE *f = fopen(LOGF, "a");
    if (f) { vfprintf(f, fmt, ap); fprintf(f, "\n"); fclose(f); }
    va_end(ap);
}

static int send_all(int c, const char *b, int n)   /* v2.4: 返回0=对端断开 */
{
    while (n > 0) { int k = send(c, b, n, 0); if (k <= 0) return 0; b += k; n -= k; }
    return 1;
}

static void send_file(int c, const char *path, const char *status)
{
    /* v2.6(P2/L-1): 静态面拒绝服务端脚本 — api.sh 与 CGI 同目录, 原样直出等于
     * 免认证泄露全部服务端逻辑/文件布局(侦察辅助)。动态入口只有 /api/<ep>。 */
    {
        size_t L = strlen(path);
        if (L >= 3 && !strcmp(path + L - 3, ".sh")) {
            const char *nf = "HTTP/1.0 404 Not Found\r\nContent-Length: 9\r\n"
                             "Connection: close\r\n\r\nnot found";
            send_all(c, nf, strlen(nf));
            logline("403[sh] %s", path);
            return;
        }
    }
    char full[512];
    snprintf(full, sizeof full, "%s%s", WWW_ROOT, path);
    FILE *f = fopen(full, "rb");
    if (!f) {
        const char *nf = "HTTP/1.0 404 Not Found\r\nContent-Length: 9\r\n"
                         "Connection: close\r\n\r\nnot found";
        send_all(c, nf, strlen(nf));
        logline("404 %s", path);
        return;
    }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    char hdr[256];
    snprintf(hdr, sizeof hdr,
             "HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %ld\r\n"
             "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
             status, mime(path), sz);
    send_all(c, hdr, strlen(hdr));
    char buf[4096]; int k;
    while ((k = fread(buf, 1, sizeof buf, f)) > 0) send_all(c, buf, k);
    fclose(f);
    logline("200 %s (%ldB)", path, sz);
}

static void send_json(int c, const char *body, int n)
{
    char hdr[160];
    snprintf(hdr, sizeof hdr,
             "HTTP/1.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
             "Content-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", n);
    send_all(c, hdr, strlen(hdr));
    send_all(c, body, n);
}

/* CGI: fork + execv, no shell anywhere in the path.
 * v2.1: CGI 子进程独立进程组 + 45s 看门狗(超时杀组) — 曾被 daemon 型 CGI
 * 的孙进程持有 stdout 管道导致串行循环永久挂死(整个 GUI 无响应)。 */
static void run_cgi(int c, const char *ep, const char *method,
                    const char *query, const char *body)
{
    int pfd[2];
    if (pipe(pfd) < 0) { send_json(c, "{\"error\":\"pipe\"}", 17); return; }
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        close(pfd[0]);
        dup2(pfd[1], 1); close(pfd[1]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 2); close(devnull); }
        char *argv[] = { (char*)"/bin/sh", (char*)WWW_ROOT "/api.sh", (char*)ep, 0 };
        char m[16], q[1024];
        char *b = body ? strdup(body) : 0;
        setenv("V3_METHOD", method, 1);
        if (query) { snprintf(q, sizeof q, "%.1000s", query); setenv("V3_QUERY", q, 1); }
        if (b) { setenv("V3_BODY", b, 1); }
        execv("/bin/sh", argv);
        _exit(127);
    }
    close(pfd[1]);
    setpgid(pid, pid);   /* 父侧也设一次, 防竞态 */
    static char bodybuf[65536];
    int total = 0, k, timedout = 0;
    time_t deadline = time(0) + 45;
    while (total < (int)sizeof bodybuf - 1) {
        struct pollfd pf = { pfd[0], POLLIN, 0 };
        int pr = poll(&pf, 1, 1500);
        if (pr == 0) { if (time(0) > deadline) { timedout = 1; break; } continue; }
        if (pr < 0) break;
        k = read(pfd[0], bodybuf + total, sizeof bodybuf - 1 - total);
        if (k <= 0) break;
        total += k;
    }
    if (timedout) { kill(-pid, SIGKILL); kill(pid, SIGKILL); }
    close(pfd[0]);
    int st; while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    if (timedout) { const char *e = "{\"error\":\"cgi_timeout\"}"; send_json(c, e, strlen(e)); logline("api %s %s TIMEOUT", method, ep); return; }
    bodybuf[total] = 0;
    send_json(c, bodybuf, total);
    logline("api %s %s (%dB)", method, ep, total);
}

/* v2.4 SSE: 流式 CGI — 响应头先行, 管道增量转发。api.sh sse 端点持续输出
 * "data: {...}

"; 寿命上限600s(子进程570s自退双保险), 空闲80s判死,
 * EventSource 客户端自动重连。 */
static void run_cgi_sse(int c, const char *ep, const char *query)
{
    int pfd[2];
    if (pipe(pfd) < 0) { send_json(c, "{\"error\":\"pipe\"}", 17); return; }
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        close(pfd[0]);
        dup2(pfd[1], 1); close(pfd[1]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 2); close(devnull); }
        char *argv[] = { (char*)"/bin/sh", (char*)WWW_ROOT "/api.sh", (char*)ep, 0 };
        setenv("V3_METHOD", "GET", 1);
        /* v2.5: 补传 V3_QUERY — 原实现漏传(api.sh sse 旧无 token 门从未暴露;
         * need_tok 需从 query 读 token, 缺此即恒 need_login) */
        if (query) { char q[1024]; snprintf(q, sizeof q, "%.1000s", query); setenv("V3_QUERY", q, 1); }
        execv("/bin/sh", argv);
        _exit(127);
    }
    close(pfd[1]);
    setpgid(pid, pid);
    static const char sse_hdr[] =
        "HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n"
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
    send_all(c, sse_hdr, sizeof sse_hdr - 1);
    char buf[4096]; int k;
    time_t t0 = time(0), last = t0;
    while (time(0) - t0 < 600) {
        struct pollfd pf = { pfd[0], POLLIN, 0 };
        int pr = poll(&pf, 1, 2000);
        if (pr == 0) { if (time(0) - last > 80) break; continue; }
        if (pr < 0) break;
        k = read(pfd[0], buf, sizeof buf);
        if (k <= 0) break;
        last = time(0);
        if (!send_all(c, buf, k)) break;   /* 客户端断开 */
    }
    kill(-pid, SIGKILL); kill(pid, SIGKILL);
    close(pfd[0]);
    int st; while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    logline("api GET %s (sse end)", ep);
}

static int ep_ok(const char *ep)
{
    if (!*ep || strlen(ep) > 48) return 0;
    for (const char *p = ep; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_'))
            return 0;
    return 1;
}

/* ---- v2.5: 全局并发计数(SIGCHLD 收尸; 原 SIG_IGN 自动收尸但不计数) ---- */
static volatile sig_atomic_t g_nconn = 0;
static void on_chld(int sig)
{
    (void)sig;
    while (waitpid(-1, 0, WNOHANG) > 0)
        if (g_nconn > 0) g_nconn--;
}

/* ---- v2.2: FH App API 隧道 ---- */
#define UP_HOST "192.168.9.1"   /* nginx 只绑 LAN IP(webs_revive conf), 不绑 loopback */
#define UP_PORT 8080

static int is_fh_proxy(const char *path)
{
    /* /fh_api/* (LG6151M/LG6851F 前缀) 与 /api/tmp/* (LG6121F 无前缀变体);
     * 我们自己的端点是 /api/<name>, "tmp/" 保留段, 无碰撞 */
    return !strncmp(path, "/fh_api/", 8) || !strncmp(path, "/api/tmp/", 9);
}

static int send_chk(int fd, const char *b, int n)
{
    while (n > 0) { int k = send(fd, b, n, 0); if (k <= 0) return -1; b += k; n -= k; }
    return 0;
}

static void proxy_tunnel(int c, char *req, int n, const char *path)
{
    int u = socket(AF_INET, SOCK_STREAM, 0);
    if (u < 0) {
        const char *e = "HTTP/1.0 500 Internal Error\r\nContent-Length: 0\r\n\r\n";
        send_all(c, e, strlen(e));
        return;
    }
    /* v2.3: 记录请求与响应头部(前240B) — 烽火终端App协议分析用 */
    char reqdump[256]; int rd = n < 240 ? n : 240;
    for (int i = 0; i < rd; i++) reqdump[i] = (req[i] >= 32 && req[i] < 127) || req[i] == '\n' ? req[i] : '.';
    reqdump[rd] = 0;
    struct sockaddr_in ua;
    memset(&ua, 0, sizeof ua);
    ua.sin_family = AF_INET;
    ua.sin_port = htons(UP_PORT);
    ua.sin_addr.s_addr = inet_addr(UP_HOST);
    if (connect(u, (struct sockaddr *)&ua, sizeof ua) < 0) {
        close(u);
        const char *e = "HTTP/1.0 502 Bad Gateway (stock webs down?)\r\n"
                        "Content-Length: 0\r\nConnection: close\r\n\r\n";
        send_all(c, e, strlen(e));
        logline("proxy %s 502 (no upstream)", path);
        return;
    }
    if (send_chk(u, req, n) < 0) { close(u); return; }
    char buf[16384];
    char respdump[256]; int rdtot = 0, respLogged = 0;
    time_t deadline = time(0) + 60;
    long relayed = n;
    for (;;) {
        if (time(0) > deadline) break;
        struct pollfd pf[2] = { { c, POLLIN, 0 }, { u, POLLIN, 0 } };
        int pr = poll(pf, 2, 1500);
        if (pr < 0) break;
        if (pr == 0) continue;                    /* 空闲 1.5s, 继续等到 deadline */
        if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            int k = recv(c, buf, sizeof buf, 0);
            if (k <= 0) break;                    /* 客户端关闭 */
            if (send_chk(u, buf, k) < 0) break;
            relayed += k;
            deadline = time(0) + 60;
        }
        if (pf[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            int k = recv(u, buf, sizeof buf, 0);
            if (k <= 0) break;                    /* 上游关闭 */
            if (send_chk(c, buf, k) < 0) break;
            if (!respLogged) {
                rdtot = k < 240 ? k : 240;
                for (int i = 0; i < rdtot; i++) respdump[i] = (buf[i] >= 32 && buf[i] < 127) || buf[i] == '\n' ? buf[i] : '.';
                respdump[rdtot] = 0;
                respLogged = 1;
            }
            deadline = time(0) + 60;
        }
    }
    close(u);
    logline("proxy REQ  | %s", reqdump);
    if (respLogged) logline("proxy RESP | %s", respdump);
    logline("proxy %s (%ldB relayed)", path, relayed);
}

int main(void)
{
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_chld;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigaction(SIGCHLD, &sa, 0);
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = inet_addr(BIND_IP);
    a.sin_port = htons(PORT);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); return 2; }
    if (listen(s, 8) < 0) { perror("listen"); return 3; }
    logline("===== v3httpd v2.6 start %s:%d root=%s =====", BIND_IP, PORT, WWW_ROOT);

    static char req[32768 + BODY_MAX];
    for (;;) {
        struct sockaddr_in ca; socklen_t cl = sizeof ca;
        int c = accept(s, (struct sockaddr *)&ca, &cl);
        if (c < 0) continue;
        /* v2.5: 并发上限 — 满则 503 立即关(不 fork, 资源面保护: 慢连/海量连接) */
        if (g_nconn >= 32) {
            static const char busy[] =
                "HTTP/1.0 503 Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send_all(c, busy, sizeof busy - 1);
            close(c);
            logline("503 busy (nconn=%d)", (int)g_nconn);
            continue;
        }
        /* v2.1: fork-per-connection 并发 — 串行循环曾因单个 CGI 挂死拖垮整个 GUI */
        pid_t h = fork();
        if (h == 0) {
            close(s);
            handle_conn(c, req, sizeof req - 1);
            close(c);
            _exit(0);
        }
        if (h > 0) { g_nconn++; close(c); }
        else close(c);
    }
    return 0;
}

static void handle_conn(int c, char *req, size_t reqsz)
{
    /* v2.5: 首包/后续包统一 8s 接收超时 — 慢连攻击(只连不发)占死子进程的根治;
     * LAN 内正常请求亚秒级, 8s 极宽松; 超时 recv 返回 EAGAIN -> k<=0 分支自退 */
    struct timeval tv = { 8, 0 };
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    int n = recv(c, req, reqsz - 1, 0);
    if (n <= 0) return;
    req[n] = 0;
    char method[8], path[1024];
    if (sscanf(req, "%7s %1023s", method, path) != 2) return;
    char *q = strchr(path, '?');
    char query[1024] = "";
    if (q) { snprintf(query, sizeof query, "%.1000s", q + 1); *q = 0; }
    /* sanitize: reject traversal */
    if (strstr(path, "..") || strchr(path, '\\')) {
        const char *bad = "HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
        send_all(c, bad, strlen(bad));
        return;
    }
    if (is_fh_proxy(path)) { proxy_tunnel(c, req, n, path); return; }
    /* v2.6(P2/M-2): Host 校验(仅非隧道面) — DNS rebinding 攻击者域名解析到本机后,
     * 浏览器发出的 Host 是攻击者域名而非本机 IP, 据此拒绝; Host 缺省放行(老客户端)。
     * 线性扫描 header 区(与 Content-Length 同款手工风格, 无 strcasestr 依赖)。 */
    {
        const char *hp = 0;
        for (const char *p = req; p && p < req + n; ) {
            if ((p[0]=='H'||p[0]=='h') && !strncasecmp(p, "Host:", 5)) { hp = p + 5; break; }
            const char *nl = strchr(p, '\n'); if (!nl) break; p = nl + 1;
        }
        if (hp) {
            while (*hp == ' ' || *hp == '\t') hp++;   /* 冒号后前导空白 */
            char host[128] = "";
            sscanf(hp, "%127[^\r\n]", host);
            if (strcmp(host, "192.168.9.1") && strcmp(host, "192.168.9.1:80")
                && strcmp(host, "[fd42:9ac1:7e50::1]")) {
                const char *bad = "HTTP/1.0 400 Bad Host\r\nContent-Length: 0\r\n\r\n";
                send_all(c, bad, strlen(bad));
                logline("400 badhost %.60s", host);
                return;
            }
        }
    }
    if (!strncmp(path, "/api/", 5)) {
        const char *ep = path + 5;
        if (!ep_ok(ep)) {
            send_json(c, "{\"error\":\"bad_endpoint\"}", 24);
        } else if (!strcmp(method, "POST")) {
            /* body = after header terminator */
            const char *hdrend = strstr(req, "\r\n\r\n");
            char body[BODY_MAX + 1] = "";
            long clen = 0;
            /* find Content-Length case-insensitively (tiny manual scan) */
            for (char *p = req; p && p < hdrend; ) {
                if ((p[0]=='C'||p[0]=='c') && !strncasecmp(p, "Content-Length:", 15)) {
                    clen = strtol(p + 15, 0, 10);
                    break;
                }
                char *nl = strchr(p, '\n'); if (!nl) break; p = nl + 1;
            }
            if (clen > BODY_MAX) clen = BODY_MAX;
            /* read the remainder if the first recv was short */
            while (hdrend && (n - (int)(hdrend + 4 - req)) < clen) {
                int k = recv(c, req + n, reqsz - 1 - n, 0);
                if (k <= 0) break;
                n += k; req[n] = 0;
                hdrend = strstr(req, "\r\n\r\n");
                if (!hdrend) break;
            }
            if (hdrend) {
                int have = n - (int)(hdrend + 4 - req);
                if (have < 0) have = 0;
                int cp = clen < have ? (int)clen : have;
                if (cp < 0) cp = 0;
                memcpy(body, hdrend + 4, cp);
                body[cp] = 0;
            }
            run_cgi(c, ep, "POST", query, body);
        } else if (!strcmp(ep, "sse")) {
            run_cgi_sse(c, ep, query);         /* v2.4: 信号推送事件流(v2.5: 带query) */
        } else {
            run_cgi(c, ep, "GET", query, 0);
        }
    } else {
        if (!strcmp(path, "/")) strcpy(path, "/index.html");
        send_file(c, path, "200 OK");
    }
}
