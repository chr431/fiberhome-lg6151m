/* mipc_cellular.c v0.15 -- 蜂窝 MIPC 直连工具（零 RIL 依赖）
 *
 * v0.15 (2026-10-17 日志加密轮): cells 解码失败时保存原始载荷
 *   /tmp/cells_decode_fail.bin + 日志记 head 12 字节 — 实机已抓到
 *   plen≈2960 / decode=-2 的间歇失败, 需区分部分帧/异种响应/新布局。
 * v0.13 (2026-10-17 日志加密轮): 结构化诊断日志 /tmp/mipc_cellular.log —
 *   每次调用至多一行(命令/msgid/端口/响应长度/rc/耗时/解码摘要); 正常调用
 *   60s 限流, 异常(rc!=0)与慢调用(>=800ms)必记; 256KB 轮转。MIPC_LOG 可改
 *   路径, MIPC_NOLOG=1 关闭。
 * v0.12 (2026-10-17 RIL 清零轮·终章): 彻底移除 libqlril/ubus 依赖 —
 *   全部读/写路径直连 modem（/dev/ttyCMIPC 裸帧）。ql_ril_service 退役,
 *   本工具不再 dlopen 任何厂商 RIL 客户端库。
 *
 * 帧格式（mipcap 抓 ql_ril_service + 裸帧实验双向实证, _re C_cells_decode §3/§12）:
 *   84 19 54 24 | seq(4B=0) | type(u16=0x0010) | msgid(u16le) | txid(u16le) | len(u16le) | payload
 *   响应 msgid = 请求+1、txid 回显、payload 为 TLV 流（8 字节对齐）。
 *   常用 msgid（RIL ubus id ↔ MIPC ↔ 线上）:
 *     0x0423 cells(get_cell_info)   → 0x0424  载荷: TLV 0x010a 计数 + 0x810b NR 数组
 *     0x044f get_band_info          → 0x0450  tag 0x0109: CQI/band/pci/arfcn/bw
 *     0x0433 set_band_mode(锁频)    → 0x0434  TLV 0x0101 UMTS/0x0102 LTE/0x0103 NR 位图
 *     0x0451 get_nr_disable_mode    → 0x0452  tag 0x0100 len1
 *     0x042d set_nr_disable_mode    → 0x042e  tag 0x0100 len1 (3=SA 5=NSA 7=双)
 *     0x0409 network_scan           → 0x040a  空请求; 结果异步(txid=0xffff)
 *     0x0003 AT 命令通道            → 0x0004  TLV 0x8100 = AT 文本
 *   短信发送走 AT 路线（与厂商 ql_sms_send_msg 同族）: AT+EMGS="号码","内容"，
 *   中文先 AT+CSCS="UCS2" 传 UCS2 hex；不经 0x0605 PDU（避免自写 PDU 编码器）。
 *
 * TLV 对齐: 值后补齐到 8 字节（(4+len+7)&~7; __re §12 修正 §3.1 的"4 字节"）。
 * 端口: ttyCMIPC0..14 单开者语义（O_RDWR 一次开同 fd 读写）; 被占口探测跳过;
 *   kill -9 中途读会把端口楔死（实测），正常 close 无此问题。
 *
 * 用法:
 *   mipc_cellular cells                 服务小区+邻区(cells JSON)
 *   mipc_cellular cellraw-direct [msgid [hexpayload]]   原始载荷(调试)
 *   mipc_cellular getbands              频段信息(0x80 口径 dump)
 *   mipc_cellular setlock lte=<list|all> nr=<list|all> [umts=<list|all>]
 *   mipc_cellular unlock                = setlock all/all/all
 *   mipc_cellular endc get | endc set <1=SA|2=NSA|3=SA+NSA>
 *   mipc_cellular scan [timeout_s]      PLMN 扫描（当前 modem 态下与厂商同超时语义）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/time.h>

static const unsigned char MIPC_MAGIC[4] = { 0x84, 0x19, 0x54, 0x24 };

/* ---------- v0.13: 结构化诊断日志 ----------
 * 每次调用至多一行 /tmp/mipc_cellular.log。限流: 正常且 <800ms 的调用每 60s
 * 至多一行(日志文件 mtime 判); 异常(rc!=0)或慢调用(>=800ms)必记。这样 GUI
 * 2s 轮询 cells 不会刷爆, 但超时/解码失败/端口占用全部留痕。 */
static const char *g_logpath = "/tmp/mipc_cellular.log";
static int g_log_on = 1;
static char g_cmd[32] = "?";
static char g_detail[192] = "";
static unsigned g_first_msgid = 0, g_last_msgid = 0;
static int g_last_rlen = 0, g_last_rc = 0, g_last_port = -1;
static long g_last_ms = 0;

static long now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void mlog_init(const char *cmd)
{
    const char *p = getenv("MIPC_LOG");
    if (p && *p) g_logpath = p;
    if (getenv("MIPC_NOLOG")) g_log_on = 0;
    snprintf(g_cmd, sizeof g_cmd, "%s", cmd ? cmd : "?");
}

static void mlog_finish(int rc)
{
    if (!g_log_on) return;
    struct stat st;
    int have = (stat(g_logpath, &st) == 0);
    time_t now = time(NULL);
    int anomaly = (rc != 0) || (g_last_ms >= 800);
    if (!anomaly && have && now - st.st_mtime < 60) return;
    char ts[32];
    struct tm *tm = localtime(&now);
    strftime(ts, sizeof ts, "%m-%d %H:%M:%S", tm);
    unsigned prim = g_first_msgid ? g_first_msgid : g_last_msgid;
    char line[512];
    snprintf(line, sizeof line,
             "%s epoch=%ld %s msgid=0x%04x last=0x%04x port=%d rlen=%d rc=%d ms=%ld detail=%s\n",
             ts, (long)now, g_cmd, prim, g_last_msgid, g_last_port, g_last_rlen, rc, g_last_ms,
             g_detail[0] ? g_detail : "-");
    int fd = open(g_logpath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    ssize_t w = write(fd, line, strlen(line)); (void)w;
    close(fd);
    if (stat(g_logpath, &st) == 0 && st.st_size > 262144) {
        char old[256];
        snprintf(old, sizeof old, "%s.1", g_logpath);
        rename(g_logpath, old);
    }
}

static int hex2bin(const char *hex, unsigned char *out, int max)
{
    int n = (int)(strlen(hex) / 2);
    if (n > max) n = max;
    for (int i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1;
        out[i] = (unsigned char)v;
    }
    return n;
}

static void dump(const unsigned char *p, int n)
{
    for (int i = 0; i < n; i++) {
        printf("%02x", p[i]);
        if ((i + 1) % 32 == 0) printf("\n");
    }
    if (n % 32) printf("\n");
}

static uint32_t R32(const unsigned char *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static const char *nr_band_of(uint32_t a)
{
    if (a >= 499200 && a <= 515200) return "N41";
    if (a >= 693330 && a <= 733000) return "N79";
    if (a >= 632640 && a <= 657000) return "N78";
    if (a >= 151600 && a <= 153600) return "N28";
    if (a >= 205416 && a <= 208916) return "N1";
    if (a >= 285416 && a <= 288916) return "N3";
    return "?";
}

/* ---------- MIPC 传输（16 位 msgid） ---------- */
static int mipc_xfer(unsigned msgid, const unsigned char *pl, int plen,
                     unsigned char *out, int outmax, int to_ms)
{
    static const int ports[] = { 11, 12, 8, 7, 6, 5, 4, 3, 0, 14, 13 };
    long t0 = now_ms();
    int fd = -1, used_port = -1;
    for (unsigned i = 0; i < sizeof ports / sizeof ports[0]; i++) {
        char dev[32];
        snprintf(dev, sizeof dev, "/dev/ttyCMIPC%d", ports[i]);
        fd = open(dev, O_RDWR | O_NONBLOCK);
        if (fd >= 0) { used_port = ports[i]; break; }
    }
    if (fd < 0) {
        g_last_msgid = msgid; g_last_port = -1; g_last_rlen = 0;
        g_last_rc = -1; g_last_ms = now_ms() - t0;
        if (!g_first_msgid) g_first_msgid = msgid;
        return -1;
    }
    unsigned char req[16 + 1024];
    int rl = 16 + (plen > 0 ? plen : 0);
    if (plen > 1024) {
        close(fd);
        g_last_msgid = msgid; g_last_port = used_port; g_last_rlen = 0;
        g_last_rc = -2; g_last_ms = now_ms() - t0;
        if (!g_first_msgid) g_first_msgid = msgid;
        return -2;
    }
    memset(req, 0, sizeof req);
    memcpy(req, MIPC_MAGIC, 4);
    req[8] = 0x10; req[9] = 0x00;                       /* type 0x0010 */
    req[10] = (unsigned char)(msgid & 0xff);            /* msgid u16le */
    req[11] = (unsigned char)((msgid >> 8) & 0xff);
    req[12] = 0x01; req[13] = 0x00;                     /* txid = 1 */
    req[14] = (unsigned char)(plen & 0xff);
    req[15] = (unsigned char)((plen >> 8) & 0xff);
    if (plen > 0) memcpy(req + 16, pl, plen);
    if (write(fd, req, rl) != rl) {
        close(fd);
        g_last_msgid = msgid; g_last_port = used_port; g_last_rlen = 0;
        g_last_rc = -2; g_last_ms = now_ms() - t0;
        if (!g_first_msgid) g_first_msgid = msgid;
        return -2;
    }

    unsigned char buf[16384];
    int have = 0, got = 0;
    struct pollfd pf = { fd, POLLIN, 0 };
    int waited = 0, idle = 0;
    unsigned want = (msgid + 1) & 0xffff;
    while (waited < to_ms && idle < 300 && got < outmax - 16) {
        int pr = poll(&pf, 1, 100);
        waited += 100;
        if (pr <= 0) { if (got > 0) idle += 100; continue; }
        idle = 0;
        int n = read(fd, buf + have, sizeof buf - have);
        if (n > 0) have += n;
        if (getenv("MIPC_DEBUG")) fprintf(stderr, "read=%d have=%d\n", n, have);
        int pos = 0;
        while (pos + 16 <= have) {
            if (memcmp(buf + pos, MIPC_MAGIC, 4)) { pos++; continue; }
            unsigned rsp_id = (unsigned)buf[pos + 10] | ((unsigned)buf[pos + 11] << 8);
            unsigned txid = (unsigned)buf[pos + 12] | ((unsigned)buf[pos + 13] << 8);
            unsigned rlen = (unsigned)buf[pos + 14] | ((unsigned)buf[pos + 15] << 8);
            if (getenv("MIPC_DEBUG")) fprintf(stderr, "hdr@%d id=0x%04x tx=0x%04x len=%u\n", pos, rsp_id, txid, rlen);
            if (rlen > 8192) { pos++; continue; }   /* 脏帧: 重同步(防越界) */
            int need = pos + 16 + (int)rlen;
            if (need > have) break;                  /* 帧未收齐: 保留 pos 等下次 read */
            if (rsp_id == want && (txid == 1 || got > 0)) {
                int take = (int)rlen;
                if (got + take > outmax) take = outmax - got;
                memcpy(out + got, buf + pos + 16, take);
                got += take;
            }
            pos = need;
        }
        if (pos > have) pos = have;                 /* 防御: 步进越界不得传负长度给 memmove */
        if (pos > 0) { memmove(buf, buf + pos, have - pos); have -= pos; }
    }
    close(fd);
    g_last_msgid = msgid; g_last_port = used_port; g_last_rlen = got;
    g_last_rc = got > 0 ? 0 : -3; g_last_ms = now_ms() - t0;
    if (!g_first_msgid) g_first_msgid = msgid;
    return got > 0 ? got : -3;
}

/* ---------- TLV（8 字节对齐） ---------- */
static int tlv_put(unsigned char *b, int off, unsigned tag, const void *v, int len)
{
    b[off] = (unsigned char)(tag & 0xff);
    b[off + 1] = (unsigned char)(tag >> 8);
    b[off + 2] = (unsigned char)(len & 0xff);
    b[off + 3] = (unsigned char)((len >> 8) & 0xff);
    if (len > 0 && v) memcpy(b + off + 4, v, len);
    int end = off + 4 + len;
    while ((end - off) % 8) b[end++] = 0;          /* 8 字节对齐(__re §12) */
    return end;
}

static int tlv_find(const unsigned char *p, int n, unsigned tag,
                    const unsigned char **val, int *len)
{
    int off = 0;
    while (off + 4 <= n) {
        unsigned tg = (unsigned)p[off] | ((unsigned)p[off + 1] << 8);
        unsigned ln = (unsigned)p[off + 2] | ((unsigned)p[off + 3] << 8);
        if (ln > 0x1000 || off + 4 + (int)ln > n) break;
        if (tg == tag) { *val = p + off + 4; *len = (int)ln; return 0; }
        off += (4 + (int)ln + 7) & ~7;          /* 8 字节对齐步进 */
    }
    return -1;
}

static unsigned rsp_result_ok(const unsigned char *p, int n)
{
    const unsigned char *v; int len;
    if (tlv_find(p, n, 0x0000, &v, &len) == 0 && len >= 4)
        return R32(v) == 0;
    return 0;
}

/* ---------- cells (0x0423 → 0x0424) ---------- */
/* TLV: 0x010a NR 计数, 0x810b NR 数组(元素 0xB8)。记录: state u8@0(1=服务),
 * plmn char[7]@1, cid@8, ta@0xC, pci@0x10, arfcn@0x14, tac@0x18(0x0FFFFFFF=无),
 * rsrp=raw@0x1C-156, sinr=raw@0x20/2-43, rsrq=raw@0x24/2-23, band u32@0x38。
 * (反汇编还原+3 对新鲜样本逐字段验证; 旧消费端 pci 0x2C 越界 bug 已修) */
struct cellrec {
    int valid, serving;
    unsigned pci, arfcn, tac, band, cid, ta;
    int rsrp, sinr, rsrq;
    char plmn[8];
};

static int cells_decode(const unsigned char *p, int n, struct cellrec *out, int maxout)
{
    unsigned nr_cnt = 0;
    const unsigned char *nr_arr = NULL; int nr_len = 0;
    int off = 0;
    while (off + 4 <= n) {
        unsigned tag = (unsigned)p[off] | ((unsigned)p[off + 1] << 8);
        unsigned len = (unsigned)p[off + 2] | ((unsigned)p[off + 3] << 8);
        if (len > 0x1000 || off + 4 + (int)len > n) break;
        const unsigned char *v = p + off + 4;
        if (tag == 0x010a && len == 4) nr_cnt = R32(v);
        else if (tag == 0x810b) { nr_arr = v; nr_len = (int)len; }
        off += (4 + (int)len + 7) & ~7;
    }
    if (!nr_arr) return -2;
    if (nr_cnt == 0 || nr_cnt > 32) nr_cnt = (unsigned)(nr_len / 0xB8);
    int k = 0;
    for (unsigned i = 0; i < nr_cnt && k < maxout; i++) {
        const unsigned char *r = nr_arr + (size_t)i * 0xB8;
        if (r + 0xB8 > p + n) break;
        struct cellrec *c = &out[k++];
        memset(c, 0, sizeof *c);
        c->valid = 1;
        c->serving = (r[0] == 1);
        memcpy(c->plmn, r + 1, 7); c->plmn[7] = 0;
        c->cid = R32(r + 8); c->ta = R32(r + 0xC);
        c->pci = R32(r + 0x10); c->arfcn = R32(r + 0x14); c->tac = R32(r + 0x18);
        c->rsrp = (int)R32(r + 0x1C) - 156;
        c->sinr = (int)(R32(r + 0x20) / 2) - 43;
        c->rsrq = (int)(R32(r + 0x24) / 2) - 23;
        c->band = R32(r + 0x38);
    }
    return k;
}

/* bw: 0x044f 响应 tag 0x0109 值内含 "100M"/"60M" ASCII(零换算) */
static void bw_from_4f(const unsigned char *p, int n, char *out, int outsz)
{
    snprintf(out, outsz, "?");
    const unsigned char *v; int len;
    if (tlv_find(p, n, 0x0109, &v, &len) != 0 || len < 8) return;
    for (int i = 0; i + 1 < len; i++) {
        int j = i;
        while (j < len && v[j] >= '0' && v[j] <= '9' && j - i < 3) j++;
        if (j > i && j < len && v[j] == 'M') {
            snprintf(out, outsz, "%.*sM", j - i, v + i);
            return;
        }
        i = j;
    }
}

static int do_cells(void)
{
    static unsigned char dpay[16384], bpay[8192];
    static struct cellrec cr[24];
    int dn = mipc_xfer(0x0423, NULL, 0, dpay, sizeof dpay, 2500);
    if (dn <= 0) {
        snprintf(g_detail, sizeof g_detail, "direct=%d", dn);
        printf("{\"error\":\"direct %d\"}\n", dn); return 3;
    }
    int fd = open("/tmp/cells_direct.bin", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) { ssize_t w = write(fd, dpay, dn); (void)w; close(fd); }
    int k = cells_decode(dpay, dn, cr, 24);
    if (k <= 0) {
        /* v0.15: 解码失败留原始载荷 — 24h 分析需要区分"部分帧/异种响应/
         * 新布局"三种可能; 只保留最近一次, 16KB 上限, 不刷 flash。 */
        int ff = open("/tmp/cells_decode_fail.bin", O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (ff >= 0) { ssize_t w = write(ff, dpay, dn); (void)w; close(ff); }
        char head[40]; int hn = dn < 12 ? dn : 12;
        for (int i = 0; i < hn; i++) sprintf(head + i * 2, "%02x", dpay[i]);
        head[hn * 2] = 0;
        snprintf(g_detail, sizeof g_detail,
                 "decode=%d plen=%d head=%s raw=/tmp/cells_decode_fail.bin", k, dn, head);
        printf("{\"error\":\"decode %d\"}\n", k); return 3;
    }
    struct cellrec *sv = NULL;
    for (int i = 0; i < k; i++) if (cr[i].serving) { sv = &cr[i]; break; }
    if (!sv) sv = &cr[0];
    char bw[12];
    static const unsigned char q4f[8] = { 0x00, 0x01, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00 };
    int bn = mipc_xfer(0x044f, q4f, 8, bpay, sizeof bpay, 1500);
    bw_from_4f(bpay, bn > 0 ? bn : 0, bw, sizeof bw);
    printf("{\"serving\":{\"band\":\"N%u\",\"arfcn\":\"%u\",\"pci\":\"%u\","
           "\"rsrp\":\"%d\",\"sinr\":\"%d\",\"bw\":\"%s\",\"plmn\":\"%s\",\"tac\":\"%u\"},",
           sv->band, sv->arfcn, sv->pci, sv->rsrp, sv->sinr,
           bw, sv->plmn, sv->tac == 0x0FFFFFFF ? 0 : sv->tac);
    printf("\"cells\":[");
    int first = 1;
    for (int i = 0; i < k; i++) {
        if (&cr[i] == sv) continue;
        struct cellrec *c = &cr[i];
        char bname[8];
        if (c->band) snprintf(bname, sizeof bname, "N%u", c->band);
        else snprintf(bname, sizeof bname, "%s", nr_band_of(c->arfcn));
        printf("%s{\"band\":\"%s\",\"arfcn\":\"%u\",\"pci\":\"%u\","
               "\"rsrp\":\"%d\",\"sinr\":\"%d\"}",
               first ? "" : ",", bname, c->arfcn, c->pci, c->rsrp, c->sinr);
        first = 0;
    }
    printf("],\"n\":%d}\n", k - 1);
    snprintf(g_detail, sizeof g_detail,
             "n=%d band=N%u arfcn=%u bw=%s rsrp=%d sinr=%d plmn=%s",
             k - 1, sv->band, sv->arfcn, bw, sv->rsrp, sv->sinr, sv->plmn);
    return 0;
}

/* ---------- 写路径 ---------- */
/* 位映射(权威, VENDOR_MAP N41→w1bit8 / N79→w2bit14): w0=n-1(1..32),
 * w1=n-33(33..64), w2=n-65(65..96)。旧 168B 路径 base=34 系 off-by-one。 */
static void bands_fill(const char *spec, uint32_t *w, int nwords)
{
    for (int i = 0; i < nwords; i++) w[i] = 0;
    if (!strcmp(spec, "all")) {
        for (int i = 0; i < nwords; i++) w[i] = 0xFFFFFFFF;
        return;
    }
    char buf[256];
    snprintf(buf, sizeof buf, "%s", spec);
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        int b = atoi(tok);
        if (!b) continue;
        int idx, bit;
        if (b >= 1 && b <= 32)       { idx = 0; bit = b - 1; }
        else if (b >= 33 && b <= 64) { idx = 1; bit = b - 33; }
        else if (b >= 65 && b <= 96) { idx = 2; bit = b - 65; }
        else { fprintf(stderr, "band %d 超范围\n", b); continue; }
        if (idx < nwords) w[idx] |= 1u << bit;
    }
}

static int do_setlock(const char *lte, const char *nr, const char *umts)
{
    uint32_t uw[1], lw[8], nw[32];
    bands_fill(umts, uw, 1);
    bands_fill(lte, lw, 8);
    bands_fill(nr, nw, 32);
    unsigned char pl[192];
    int off = 0;
    off = tlv_put(pl, off, 0x0101, uw, 4);
    off = tlv_put(pl, off, 0x0102, lw, 32);
    off = tlv_put(pl, off, 0x0103, nw, 128);
    static unsigned char rsp[2048];
    int rn = mipc_xfer(0x0433, pl, off, rsp, sizeof rsp, 2500);
    printf("lte[%08x %08x] nr[%08x %08x %08x] umts[%08x]\n",
           lw[0], lw[1], nw[0], nw[1], nw[2], uw[0]);
    if (rn <= 0) {
        snprintf(g_detail, sizeof g_detail, "setlock lte=%s nr=%s rsp=%d", lte, nr, rn);
        printf("ret=%d (0x%x)\n", rn, rn); return 3;
    }
    int ok = rsp_result_ok(rsp, rn);
    snprintf(g_detail, sizeof g_detail, "setlock lte=%s nr=%s ret=%d", lte, nr, ok ? 0 : -1);
    printf("ret=%d (0x%x)\n", ok ? 0 : -1, ok ? 0 : 0xffffffff);
    return ok ? 0 : 3;
}

static int do_endc(int argc, char **argv)
{
    static unsigned char rsp[2048];
    if (argc >= 3 && !strcmp(argv[2], "get")) {
        int rn = mipc_xfer(0x0451, NULL, 0, rsp, sizeof rsp, 2000);
        if (rn <= 0) {
            snprintf(g_detail, sizeof g_detail, "endc get rsp=%d", rn);
            printf("{\"ret\":%d}\n", rn); return 3;
        }
        const unsigned char *v; int len;
        int mode = -1;
        if (tlv_find(rsp, rn, 0x0100, &v, &len) == 0 && len >= 1) mode = v[0];
        snprintf(g_detail, sizeof g_detail, "endc get raw=%d endc=%d", mode,
                 mode == 3 ? 1 : mode == 5 ? 2 : mode == 7 ? 3 : -1);
        printf("{\"ret\":0,\"nr_disable_mode\":%d,\"endc\":%d}\n", mode,
               mode == 3 ? 1 : mode == 5 ? 2 : mode == 7 ? 3 : -1);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[2], "set")) {
        int e = atoi(argv[3]);
        int target = (e == 1) ? 3 : (e == 2) ? 5 : (e == 3) ? 7 : -1;
        if (target < 0) { puts("bad endc (1=SA 2=NSA 3=SA+NSA)"); return 1; }
        unsigned char pl[8];
        int off = tlv_put(pl, 0, 0x0100, &target, 1);
        int rn = mipc_xfer(0x042d, pl, off, rsp, sizeof rsp, 2500);
        if (rn <= 0) {
            snprintf(g_detail, sizeof g_detail, "endc set=%d rsp=%d", target, rn);
            printf("{\"ret\":%d}\n", rn); return 3;
        }
        int ok = rsp_result_ok(rsp, rn);
        int rb = -1;
        rn = mipc_xfer(0x0451, NULL, 0, rsp, sizeof rsp, 2000);
        if (rn > 0) {
            const unsigned char *v; int len;
            if (tlv_find(rsp, rn, 0x0100, &v, &len) == 0 && len >= 1) rb = v[0];
        }
        snprintf(g_detail, sizeof g_detail, "endc set=%d ret=%d readback=%d", target, ok ? 0 : 3, rb);
        printf("{\"ret\":%d,\"set\":%d,\"readback\":%d}\n", ok ? 0 : 3, target, rb);
        return ok ? 0 : 3;
    }
    puts("usage: mipc_cellular endc get | endc set <1|2|3>");
    return 2;
}

/* getbands: 0x044f ×2 (val 01=LTE / 02=NR), 输出按旧 0x80 口径 dump */
static int do_getbands(void)
{
    static unsigned char rsp[4096], bi[512];
    memset(bi, 0, sizeof bi);
    unsigned nr_band = 0, nr_arfcn = 0; int cqi = -1;
    for (int k = 0; k < 2; k++) {
        unsigned char req[8] = { 0x00, 0x01, 0x01, 0x00, (unsigned char)(k ? 2 : 1), 0, 0, 0 };
        int rn = mipc_xfer(0x044f, req, 8, rsp, sizeof rsp, 2000);
        if (rn <= 0) continue;
        const unsigned char *v; int len;
        if (tlv_find(rsp, rn, 0x0109, &v, &len) == 0 && len >= 0x18) {
            cqi = v[5];
            nr_band = (unsigned)(v[8] | (v[9] << 8));
            nr_arfcn = R32(v + 0xC);
            memcpy(bi + 0x14, v + 0x10, 8);
        }
    }
    memcpy(bi + 2, &nr_band, 2);
    memcpy(bi + 0x25, &cqi, 1);
    memcpy(bi + 0x34, &nr_arfcn, 4);
    snprintf(g_detail, sizeof g_detail, "getbands cqi=%d band=%u arfcn=%u", cqi, nr_band, nr_arfcn);
    printf("ret=0\n");
    dump(bi, 256);
    return 0;
}

/* scan: 0x0409 空请求; 结果异步(0x09/0x0a, txid=0xffff)。当前 modem 态下厂商
 * 路径同样超时(实弹对照), 直连保持同等语义: 收不到结果即 timeout。 */
static int do_scan(int timeout_s)
{
    static unsigned char rsp[8192];
    int rn = mipc_xfer(0x0409, NULL, 0, rsp, sizeof rsp, timeout_s * 1000);
    if (rn > 0) {
        const unsigned char *v; int len;
        if (tlv_find(rsp, rn, 0x0100, &v, &len) == 0 && len >= 4) {
            unsigned cnt = R32(v);
            if (cnt > 0 && cnt <= 32) {
                snprintf(g_detail, sizeof g_detail, "scan count=%u rlen=%d", cnt, rn);
                printf("{\"count\":%u,\"networks\":[]}\n", cnt);
                return 0;
            }
        }
    }
    snprintf(g_detail, sizeof g_detail, "scan timeout=%ds rsp=%d", timeout_s, rn);
    printf("{\"error\":\"timeout_%ds\"}\n", timeout_s);
    return 4;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        puts("usage: mipc_cellular cells | getbands | unlock\n"
             "                setlock lte=<list|all> nr=<list|all> [umts=<list|all>]\n"
             "                endc get | endc set <1=SA|2=NSA|3=SA+NSA>\n"
             "                scan [timeout_s] | cellraw-direct [msgid [hex]]");
        return 1;
    }
    mlog_init(argv[1]);
    int rc = 1;
    if (!strcmp(argv[1], "cells")) rc = do_cells();
    else if (!strcmp(argv[1], "getbands")) rc = do_getbands();
    else if (!strcmp(argv[1], "unlock")) rc = do_setlock("all", "all", "all");
    else if (!strcmp(argv[1], "setlock") && argc >= 3) {
        const char *lte = "all", *nr = "all", *umts = "all";
        for (int i = 2; i < argc; i++) {
            if (!strncmp(argv[i], "lte=", 4)) lte = argv[i] + 4;
            else if (!strncmp(argv[i], "nr=", 3)) nr = argv[i] + 3;
            else if (!strncmp(argv[i], "umts=", 5)) umts = argv[i] + 5;
        }
        rc = do_setlock(lte, nr, umts);
    }
    else if (!strcmp(argv[1], "endc")) rc = do_endc(argc, argv);
    else if (!strcmp(argv[1], "scan")) rc = do_scan(argc >= 3 ? atoi(argv[2]) : 60);
    else if (!strcmp(argv[1], "cellraw-direct")) {
        static unsigned char dpay[16384], req[512];
        int reqlen = 0;
        unsigned msgid = 0x0423;
        if (argc >= 3) msgid = (unsigned)strtoul(argv[2], NULL, 0);
        if (msgid < 0x0100) msgid |= 0x0400;      /* 兼容旧的 8 位写法(0x23→0x0423) */
        if (argc >= 4) reqlen = hex2bin(argv[3], req, sizeof req);
        int dn = mipc_xfer(msgid, reqlen > 0 ? req : NULL, reqlen, dpay, sizeof dpay, 2000);
        if (dn <= 0) {
            snprintf(g_detail, sizeof g_detail, "cellraw msgid=0x%04x rsp=%d", msgid, dn);
            printf("directerr %d\n", dn); rc = 4;
        } else {
            for (int i = 0; i < dn; i++) printf("%02x", dpay[i]);
            printf("\n");
            snprintf(g_detail, sizeof g_detail, "cellraw msgid=0x%04x len=%d", msgid, dn);
            rc = 0;
        }
    }
    else {
        snprintf(g_detail, sizeof g_detail, "unknown command");
        puts("unknown command");
    }
    mlog_finish(rc);
    return rc;
}
