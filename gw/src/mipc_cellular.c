/* mipc_cellular.c v0.2 -- 蜂窝 MIPC 直连工具 (ROADMAP P1 引擎底层)
 *
 * 通道 (2026-10-05 实证): 本进程 dlopen libqlril.so 闭包(RTLD_GLOBAL 预载
 * libql_uinf 等 -- libqlril 不在 DT_NEEDED 声明它, 宿主供给模式) -> ql_nw_init(0)
 * -> ql_nw_set/get_band_mode -> ubus ril -> ql_ril_service -> MIPC TLV -> modem。
 * 全程不经 fhrom mobilenetwork / cfgmgr。
 *
 * 168B 请求结构 (capstone 逆向 mobilenetwork 0x4108d4-0x410fa8 + 实弹验证):
 *   u32@0x00 mode (3=应用频段锁)
 *   u32@0x04 umts_band_mode 位图 (band n -> bit n-1, n<=32)
 *   u32@0x08 LTE 位图 w0: bands 1-32  -> bit n-1
 *   u32@0x0C LTE 位图 w1: bands 34-65 -> bit n-33
 *   u64@0x28 NR 位图 w0+w1: bands 1-32 (bit n-1) + bands 34-65 (bit n-33)
 *   u32@0x30 NR 位图 w2: bands 66-96  -> bit n-65   (N41->@0x2C bit8, N79->@0x30 bit14)
 *   其余字段保持 0。掩码全 1 = 不限制 (解锁)。
 * 实弹记录: 锁 NR{41,79} ret=0 树小区列表即时只剩 N41/N79; 全 1 解锁 ret=0;
 * 每次变更 modem 重扫 ~20-60s, PDN 由 mobilenetwork 重拨(过渡期)。
 *
 * 用法:
 *   mipc_cellular getbands
 *   mipc_cellular setlock lte=1,3,38,40,41 nr=41,79 [umts=all|1,8]
 *   mipc_cellular unlock
 *   mipc_cellular setbands <hex336>   (原始 blob, 调试用)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>   /* v0.7 引入: smswatch 落盘用; usleep 由 musl 头提供
                         (原 static 自声明因头文件缺席而存在, 今删) */

static int (*p_get_band_info)(void *);
static int (*p_set_band_mode)(const void *);
static int (*p_nw_init)(int);
static int (*p_sms_init)(int);
static int (*p_sms_send_msg)(const void *);
static int (*p_nw_set_pdu_recv_cb)(void (*)(const void *));
static int (*p_sms_get_store_number)(void);
static int (*p_nw_scan)(void *, void (*)(int, void *));
static int (*p_scan_busy)(void);
static int (*p_get_cell_info)(void *);

static int load_lib(const char *path)
{
    /* libqlril 不在 DT_NEEDED 里声明 libql_uinf (宿主供给模式, mobilenetwork
     * 同款): 必须先以 RTLD_GLOBAL 装载依赖闭包, 再装 libqlril。 */
    static const char *pre[] = {
        "libql_qlog.so", "libmipc_msg.so", "libubox.so.20230523",
        "libubus.so.20230605", "libuci.so", "libql_uinf.so", NULL,
    };
    for (int i = 0; pre[i]; i++) {
        char full[128];
        void *ph;
        snprintf(full, sizeof full, "/usr/lib/%s", pre[i]);
        ph = dlopen(full, RTLD_NOW | RTLD_GLOBAL);
        if (!ph) {
            snprintf(full, sizeof full, "/lib/%s", pre[i]);
            ph = dlopen(full, RTLD_NOW | RTLD_GLOBAL);
        }
        if (!ph) fprintf(stderr, "preload %s: %s\n", pre[i], dlerror());
    }
    void *h = dlopen(path, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen(%s): %s\n", path, dlerror());
        return -1;
    }
    p_get_band_info = (int (*)(void *))dlsym(h, "ql_nw_get_band_info");
    p_set_band_mode = (int (*)(const void *))dlsym(h, "ql_nw_set_band_mode");
    p_nw_init = (int (*)(int))dlsym(h, "ql_nw_init");
    p_sms_init = (int (*)(int))dlsym(h, "ql_sms_init");
    p_sms_send_msg = (int (*)(const void *))dlsym(h, "ql_sms_send_msg");
    /* v0.7: 接收消费者(可选装载, smswatch 用) — 缺失不算致命 */
    p_nw_set_pdu_recv_cb = (int (*)(void (*)(const void *)))dlsym(h, "ql_sms_set_pdu_recv_cb");
    p_sms_get_store_number = (int (*)(void))dlsym(h, "ql_sms_get_store_message_number");
    p_nw_scan = (int (*)(void *, void (*)(int, void *)))dlsym(h, "ql_nw_network_scan");
    p_scan_busy = (int (*)(void))dlsym(h, "ql_nw_net_scan_async_f");
    p_get_cell_info = (int (*)(void *))dlsym(h, "ql_nw_get_cell_info");
    if (!p_get_band_info || !p_set_band_mode || !p_nw_init ||
        !p_sms_init || !p_sms_send_msg || !p_nw_scan) {
        fprintf(stderr, "dlsym: %s\n", dlerror());
        return -1;
    }
    return 0;
}

static void dump(const unsigned char *p, int n)
{
    for (int i = 0; i < n; i++) {
        printf("%02x", p[i]);
        if ((i + 1) % 32 == 0) printf("\n");
    }
    if (n % 32) printf("\n");
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

/* 频段列表 -> 位图字。返回写入的 32 位字数 (0/1/2), 超范围频段打警告。 */
static uint32_t g_warn;
static int bands_to_words(const char *spec, uint32_t *w0, uint32_t *w1, uint32_t *w2,
                          int base0, int base1, int base2)
{
    /* base0/1/2 = 三段起始频段号 (LTE: 1,34,66+ 不存在; NR: 1,34,66) */
    *w0 = *w1 = *w2 = 0;
    if (!strcmp(spec, "all")) {
        *w0 = *w1 = 0xFFFFFFFF;
        if (base2 > 0) *w2 = 0xFFFFFFFF;
        return 3;
    }
    char buf[256];
    snprintf(buf, sizeof buf, "%s", spec);
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        int b = atoi(tok);
        if (!b) continue;
        if (b >= base0 && b < base1) *w0 |= 1u << (b - base0);
        else if (b >= base1 && b < base2) *w1 |= 1u << (b - base1);
        else if (base2 > 0 && b >= base2 && b <= base2 + 31) *w2 |= 1u << (b - base2);
        else { fprintf(stderr, "band %d 超出可编码范围\n", b); g_warn++; }
    }
    return 3;
}

static void build_and_send(const char *lte, const char *nr, const char *umts)
{
    unsigned char b[0xA8];
    uint32_t lw0, lw1, lw2, nw0, nw1, nw2, uw0, uw1, uw2;
    memset(b, 0, sizeof b);
    bands_to_words(lte, &lw0, &lw1, &lw2, 1, 34, 66);  /* LTE w1=34-65; v0.2 原 base2=0 使
        [34,0) 恒假 = 38/39/40/41(国内主力)永远编不进(2026-10-07 实弹); ≥66 无 w2 字段, 落 w2 即弃 */
    bands_to_words(nr,  &nw0, &nw1, &nw2, 1, 34, 65);   /* w2: n-65 (厂商 0x410f68: sub 0x41) */
    bands_to_words(umts, &uw0, &uw1, &uw2, 1, 34, 0);
    /* umts 仅 u32@4 单字 */
    uint32_t mode = 3;
    memcpy(b + 0x00, &mode, 4);
    memcpy(b + 0x04, &uw0, 4);
    memcpy(b + 0x08, &lw0, 4);
    memcpy(b + 0x0C, &lw1, 4);
    memcpy(b + 0x28, &nw0, 4);
    memcpy(b + 0x2C, &nw1, 4);
    memcpy(b + 0x30, &nw2, 4);
    printf("lte[%08x %08x] nr[%08x %08x %08x] umts[%08x]\n",
           lw0, lw1, nw0, nw1, nw2, uw0);
    int r = p_set_band_mode(b);
    printf("ret=%d (0x%x)\n", r, r);
    if (r) printf("NOTE: modem 重扫约 20-60s, PDN 由上层重拨\n");
}

/* 服务小区 + CA 小区列表 (D 组逆向 2026-10-06, 写树顺序三角互证):
 * ql_nw_get_band_info(0x80): lte_band u16@0, nr_band u16@2, nr_dl bw[8]@0x14,
 *   serving NR-ARFCN u32@0x34, nr CQI u8@0x25
 * ql_nw_get_cell_info(0x8C8): rat u32@0(0x12=NR SA), nr_avail u8@0x500,
 *   nr_cnt u8@0x501, PLMN char[8]@0x510, TAC u32@0x518, PCI u32@0x51C,
 *   cells[]@0x528 stride 0x30 x20: rsrp s32@0, rsrq s32@4, sinr s32@8,
 *   pci u32@0x24, arfcn u32@0x28; cells[0]=服务小区(与服务块同址互证)
 * band 由 arfcn 现算(与 mobilenetwork fh_convert_arfcn_to_band 同思路)。 */
struct bi { unsigned char b[0x80]; };
struct ci { unsigned char b[0x8C8]; };
/* 布局(cellraw 实测 2026-10-06, 与树值/直读三角互证):
 *   PLMN char@0x510, TAC u32@0x518, PCI(服务) u32@0x51C,
 *   cells 基址 0x520, stride 0x30: arfcn u32@+0x00, rsrp s32@+0x08,
 *   sinr s32@+0x0C, PCI u32@+0x2C; cells[0]=服务小区; count=nr_cnt u8@0x501 */
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

static int do_cells(void)
{
    struct bi bi; struct ci ci;
    memset(&bi, 0, sizeof bi); memset(&ci, 0, sizeof ci);
    int r1 = p_get_band_info(&bi);
    int r2 = p_get_cell_info(&ci);
    if (r1 || r2) { printf("{\"error\":\"ret %d/%d\"}\n", r1, r2); return 3; }
    uint16_t nr_band; memcpy(&nr_band, bi.b + 2, 2);
    char bw[9]; memcpy(bw, bi.b + 0x14, 8); bw[8] = 0;
    int n = ci.b[0x501] > 20 ? 20 : ci.b[0x501];
    const unsigned char *c0 = ci.b + 0x520;
    printf("{\"serving\":{\"band\":\"N%d\",\"arfcn\":\"%u\",\"pci\":\"%u\","
           "\"rsrp\":\"%d\",\"sinr\":\"%d\",\"bw\":\"%s\",\"plmn\":\"%.6s\",\"tac\":\"%u\"},",
           nr_band, R32(c0), R32(ci.b + 0x51C),
           (int32_t)R32(c0 + 8), (int32_t)R32(c0 + 0xC),
           bw, ci.b + 0x510, R32(ci.b + 0x518));
    printf("\"cells\":[");
    for (int i = 0; i < n; i++) {
        const unsigned char *r = ci.b + 0x520 + (size_t)i * 0x30;
        printf("%s{\"band\":\"%s\",\"arfcn\":\"%u\",\"pci\":\"%u\","
               "\"rsrp\":\"%d\",\"sinr\":\"%d\"}",
               i ? "," : "", nr_band_of(R32(r)), R32(r), R32(r + 0x2C),
               (int32_t)R32(r + 8), (int32_t)R32(r + 0xC));
    }
    printf("],\"n\":%d}\n", n);
    return 0;
}

/* ql_sms_send_msg 结构 (B 组逆向 2026-10-06, 构包侧交叉证实):
 *   u32  @0x000 format: 0=GSM7文本 1=binary 2=UCS2(BE字节)
 *   char @0x004 addr[0xFC]  目的号码 NUL 结尾
 *   u32  @0x104 content_len (<=0x5A0)
 *   u8   @0x108 content[0x5A0]
 * ql_sms_init(0) 必须先调; 同步语义: 返回 0 即发送成功。 */
struct sms_msg {
    uint32_t format;
    char addr[0xFC];
    uint32_t pad;
    uint32_t content_len;
    unsigned char content[0x5A0];
};

/* ql_nw_network_scan 响应结构 (C 组逆向 2026-10-06, 三方互证):
 *   int32 err; int32 count; plmn[32] stride 0x94:
 *     long_name[65]@0 / short_name[65]@0x41 / mcc[4]@0x82 / mnc[4]@0x86
 *     / status@0x8c / rat@0x90 (2=GSM 4=LTE 15=UMTS 18=NR5G)
 * 异步: cb(err, resp) 于 libql_uinf 后台线程触发, resp 仅在 cb 内有效(memcpy!)
 * 失败路径不调 cb -> 必须超时轮询; 库内零超时。mnc 服务端只拷 2 字节。 */
struct scan_resp {
    int32_t err;
    int32_t count;
    unsigned char plmn[32][0x94];
};

/* ---- v0.7: 短信接收消费者 (smswatch) ----
 * 背景(2026-10-07 实弹): v4 无 mobilenetwork => 无人 ql_sms_set_pdu_recv_cb
 * 注册 => 入信 RIL 事件无消费者丢弃(MO 发送正常/MT 全灭, 与 CMGF/RAT 无关)。
 * 本模式注册最小消费者: 回调原始结构体 hex 落盘 /data/gw/sms_rx.log。
 * 逆向锚点(mobilenetwork aarch64): 注册点 0x40c59c-0x40c5a0, cb=0x413f40
 * 单指针入参 x0; cb 内 [p+0]=u32(type==1 走状态报告分支), [p+4]=u16
 * (以 %d 进厂商日志)。精确布局由下一封实测入信揭示。 */
static void sms_rx_dump(const void *p)
{
    if (!p) return;
    char buf[0x600];
    int n = snprintf(buf, sizeof buf, "[%ld] recv:", (long)time(0));
    const unsigned char *b = (const unsigned char *)p;
    for (int i = 0; i < 0x180 && n < (int)sizeof buf - 4; i++)
        n += snprintf(buf + n, sizeof buf - n, "%02x", b[i]);
    n += snprintf(buf + n, sizeof buf - n, "\n");
    int fd = open("/data/gw/sms_rx.log", O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        ssize_t w = write(fd, buf, n); (void)w;
        close(fd);
    }
}

static int do_smswatch(void)
{
    if (!p_nw_set_pdu_recv_cb) { puts("no ql_sms_set_pdu_recv_cb"); return 1; }
    int ir = p_sms_init(0);
    int rr = p_nw_set_pdu_recv_cb(sms_rx_dump);
    printf("smswatch: init(0)=%d cb_reg=%d store_n=%s%d\n", ir, rr,
           p_sms_get_store_number ? "" : "?",
           p_sms_get_store_number ? p_sms_get_store_number() : -1);
    fflush(stdout);
    for (;;) pause();
    return 0;
}

static volatile int g_scan_done;
static struct scan_resp g_scan_buf;

static void scan_cb(int err, void *resp)
{
    if (err == 0 && resp) memcpy(&g_scan_buf, resp, sizeof g_scan_buf);
    g_scan_done = err == 0 ? 1 : 2;
}

static const char *rat_name(int r)
{
    switch (r) {
    case 2: return "GSM"; case 4: return "LTE"; case 15: return "UMTS";
    case 18: return "NR5G"; default: return "?";
    }
}

static int do_scan(int timeout_s)
{
    int r = p_nw_scan(NULL, scan_cb);
    if (r) { printf("{\"error\":\"scan_start_0x%x\"}\n", r); return 3; }
    for (int i = 0; i < timeout_s * 2 && !g_scan_done; i++) usleep(500 * 1000);
    if (!g_scan_done) { printf("{\"error\":\"timeout_%ds\"}\n", timeout_s); return 4; }
    if (g_scan_done == 2) { printf("{\"error\":\"scan_failed\"}\n"); return 5; }
    printf("{\"count\":%d,\"networks\":[", g_scan_buf.count);
    for (int i = 0; i < g_scan_buf.count && i < 32; i++) {
        const unsigned char *e = g_scan_buf.plmn[i];
        const char *ln = (const char *)e;            /* long_name[65] */
        const char *mcc = (const char *)e + 0x82;    /* mcc[4]  */
        const char *mnc = (const char *)e + 0x86;    /* mnc[4](第3位可能未拷) */
        int status = *(int32_t *)(e + 0x8c);
        int rat = *(int32_t *)(e + 0x90);
        printf("%s{\"name\":\"%s\",\"mcc\":\"%.3s\",\"mnc\":\"%.2s\",\"status\":%d,\"rat\":\"%s\"}",
               i ? "," : "", ln, mcc, mnc, status, rat_name(rat));
    }
    printf("]}\n");
    return 0;
}

static int do_send(int format, const char *num, const char *payload, int payload_is_hex)
{
    struct sms_msg m;
    memset(&m, 0, sizeof m);
    m.format = (uint32_t)format;
    snprintf(m.addr, sizeof m.addr, "%s", num);
    if (payload_is_hex) {
        int n = hex2bin(payload, m.content, sizeof m.content);
        if (n < 0) { puts("bad hex"); return 1; }
        m.content_len = (uint32_t)n;
    } else {
        int n = (int)strlen(payload);
        if (n > (int)sizeof m.content) n = (int)sizeof m.content;
        memcpy(m.content, payload, n);
        m.content_len = (uint32_t)n;
    }
    int ir = p_sms_init(0);
    if (ir) fprintf(stderr, "ql_sms_init(0)=%d (0x%x)\\n", ir, ir);
    int r = p_sms_send_msg(&m);
    printf("ret=%d (0x%x)\\n", r, r);
    return r ? 3 : 0;
}

int main(int argc, char **argv)
{
    const char *lib = getenv("QLRIL_SO");
    if (!lib || !*lib) lib = "/usr/lib/libqlril.so";
    if (load_lib(lib)) return 2;
    int ir = p_nw_init(0);
    if (ir) fprintf(stderr, "ql_nw_init(0)=%d (0x%x)\n", ir, ir);

    if (argc >= 2 && !strcmp(argv[1], "getbands")) {
        unsigned char buf[512];
        memset(buf, 0, sizeof buf);
        int r = p_get_band_info(buf);
        printf("ret=%d\n", r);
        dump(buf, 256);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "unlock")) {
        build_and_send("all", "all", "all");
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "setlock")) {
        const char *lte = "all", *nr = "all", *umts = "all";
        for (int i = 2; i < argc; i++) {
            if (!strncmp(argv[i], "lte=", 4)) lte = argv[i] + 4;
            else if (!strncmp(argv[i], "nr=", 3)) nr = argv[i] + 3;
            else if (!strncmp(argv[i], "umts=", 5)) umts = argv[i] + 5;
        }
        build_and_send(lte, nr, umts);
        return g_warn ? 3 : 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "setbands")) {
        unsigned char req[0xA8];
        memset(req, 0, sizeof req);
        int n = hex2bin(argv[2], req, sizeof req);
        if (n < 0) { puts("bad hex"); return 1; }
        printf("req_len=%d\n", n);
        int r = p_set_band_mode(req);
        printf("ret=%d (0x%x)\n", r, r);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "cellraw")) {
        struct ci ci; memset(&ci, 0, sizeof ci);
        p_get_cell_info(&ci);
        unsigned char *p = (unsigned char *)&ci;
        for (int i = 0; i < 0x700; i++) printf("%02x", p[i]);
        printf("\n");
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "cells"))          /* 服务+CA 小区列表 */
        return do_cells();
    if (argc >= 2 && !strcmp(argv[1], "scan"))           /* PLMN 扫描(10-60s) */
        return do_scan(argc >= 3 ? atoi(argv[2]) : 60);
    if (argc >= 4 && !strcmp(argv[1], "sendsms"))        /* ASCII/GSM7 */
        return do_send(0, argv[2], argv[3], 0);
    if (argc >= 4 && !strcmp(argv[1], "senducs2"))       /* 中文: UCS2-BE hex */
        return do_send(2, argv[2], argv[3], 1);
    if (argc >= 2 && !strcmp(argv[1], "smswatch"))       /* v0.7: 入信消费者 */
        return do_smswatch();
    puts("usage: mipc_cellular getbands | unlock | smswatch\n"
         "                setlock lte=<list|all> nr=<list|all> [umts=<list|all>]\n"
         "                setbands <hexblob>\n"
         "                sendsms <num> <ascii-text> | senducs2 <num> <ucs2-be-hex>\n"
         "                scan [timeout_s]");
    return 1;
}
