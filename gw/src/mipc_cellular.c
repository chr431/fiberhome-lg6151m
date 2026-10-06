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

static int (*p_get_band_info)(void *);
static int (*p_set_band_mode)(const void *);
static int (*p_nw_init)(int);
static int (*p_sms_init)(int);
static int (*p_sms_send_msg)(const void *);

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
    if (!p_get_band_info || !p_set_band_mode || !p_nw_init ||
        !p_sms_init || !p_sms_send_msg) {
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
    bands_to_words(lte, &lw0, &lw1, &lw2, 1, 34, 0);      /* LTE 无 66+ 段 */
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
    if (argc >= 4 && !strcmp(argv[1], "sendsms"))        /* ASCII/GSM7 */
        return do_send(0, argv[2], argv[3], 0);
    if (argc >= 4 && !strcmp(argv[1], "senducs2"))       /* 中文: UCS2-BE hex */
        return do_send(2, argv[2], argv[3], 1);
    puts("usage: mipc_cellular getbands | unlock\n"
         "                setlock lte=<list|all> nr=<list|all> [umts=<list|all>]\n"
         "                setbands <hexblob>\n"
         "                sendsms <num> <ascii-text> | senducs2 <num> <ucs2-be-hex>");
    return 1;
}
