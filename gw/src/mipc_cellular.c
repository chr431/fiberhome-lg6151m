/* mipc_cellular.c v0.1 -- 蜂窝 MIPC 直连工具 (ROADMAP P1/P2 基石)
 *
 * 背景 (VENDOR_MAP §4 / C 报告): 锁频段无 AT 面, 唯一路径是
 * libqlril.so 的 ql_nw_set_band_mode(168B 结构体, RIL req 0x50f,
 * 经 ubus ril -> ql_ril_service -> MIPC TLV -> modem)。
 * 本工具链接期直接挂 libqlril, 提供自研引擎的底层 CLI:
 *
 *   mipc_cellular getbands            查询当前频段位图 -> hex dump
 *   mipc_cellular setbands <hexblob>  下发 168B 请求 (结构语义见下)
 *
 * ql_nw_set_band_mode 输入结构 (capstone 逆向 0x9b7c):
 *   [0x00] u64   (首字段, 候选 lte|nr 位图对)
 *   [0x08] 32B   (4xu64, 候选 umts+保留/数组)
 *   [0x28] 128B  (16xu64 频段数组区)
 *   总长 0xA8=168, 与 ubus ril_request len 一致
 * ql_nw_get_band_info(buf): 响应数据回填调用方缓冲, 位图语义用
 * getbands 实测对照当前服务小区 (N41/N79) 反推。
 *
 * 构建见 tools/build_mipc_cellular.sh (zig cc, 链 rp103 树的 libqlril.so;
 * musl 动态可执行, 运行时解析 /usr/lib/libqlril.so 及其依赖)。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>

static int (*p_get_band_info)(void *);
static int (*p_set_band_mode)(const void *);
static int (*p_nw_init)(int);

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
        snprintf(full, sizeof full, "/usr/lib/%s", pre[i]);
        void *ph = dlopen(full, RTLD_NOW | RTLD_GLOBAL);
        if (!ph) {  /* /lib 副本回退 */
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
    if (!p_get_band_info || !p_set_band_mode || !p_nw_init) {
        fprintf(stderr, "dlsym: %s\n", dlerror());
        return -1;
    }
    return 0;
}

static void dump(const unsigned char *p, int n, int per_line)
{
    for (int i = 0; i < n; i++) {
        printf("%02x", p[i]);
        if ((i + 1) % per_line == 0) printf("\n");
    }
    if (n % per_line) printf("\n");
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

int main(int argc, char **argv)
{
    const char *lib = getenv("QLRIL_SO");
    if (!lib || !*lib) lib = "/usr/lib/libqlril.so";
    if (load_lib(lib)) return 2;
    int ir = p_nw_init(0);   /* 单 int 参数(反汇编 0x5c4c: w0->w20) */
    if (ir) fprintf(stderr, "ql_nw_init(0)=%d (0x%x)\n", ir, ir);

    if (argc >= 2 && !strcmp(argv[1], "getbands")) {
        unsigned char buf[512];
        memset(buf, 0, sizeof buf);
        int r = p_get_band_info(buf);
        printf("ret=%d\n", r);
        dump(buf, 256, 32);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "setbands")) {
        unsigned char req[0xA8];
        memset(req, 0, sizeof req);
        int n = hex2bin(argv[2], req, sizeof req);
        if (n < 0) { puts("bad hex"); return 1; }
        printf("req_len=%d\n", n);
        int r = p_set_band_mode(req);
        printf("ret=%d\n", r);
        return 0;
    }
    puts("usage: mipc_cellular getbands | setbands <hexblob(<=336hex)>");
    return 1;
}
