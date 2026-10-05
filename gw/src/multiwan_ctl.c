/* multiwan_ctl.c v1.1 -- vendor multiwan engine control (direct link).
 * RE basis (subagent 2026-10-04, protocolmgr@0x4178f0 memset 0x24):
 *   fhdrv_net_set_multiwan_mode(struct 9*u32 = 36B):
 *     +0x00 enable      +0x14 wan1_percent   (wan1+wan2 must == 100)
 *     +0x04 wan1_mark   +0x18 wan2_percent
 *     +0x08 wan2_mark   +0x1C wan1_status    (0/1)
 *     +0x0C wan1_mask   +0x20 wan2_status
 *     +0x10 wan2_mask
 * Build (zig, dynamic against vendor lib):
 *   zig cc -target aarch64-linux-musl tools/multiwan_ctl.c -o multiwan_ctl \
 *     -Lrootfs_b/fhrom/lib -l:libfhdrv_net_api.so \
 *     -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 -Wl,-rpath,/fhrom/lib
 * Usage: multiwan_ctl <enable> <w1_pct> <w2_pct> <s1> <s2>
 * Exit: 0 ok, 1 usage, 4 lib returned nonzero
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct mw {
    unsigned int enable;
    unsigned int wan1_mark;
    unsigned int wan2_mark;
    unsigned int wan1_mask;
    unsigned int wan2_mask;
    unsigned int wan1_percent;
    unsigned int wan2_percent;
    unsigned int wan1_status;
    unsigned int wan2_status;
};

extern int fhdrv_net_set_multiwan_mode(struct mw *);
extern int fhdrv_net_set_multiwan_mac_config(void *);  /* {mac[6],pad[2],u32 op} */

static int hexbyte(const char *s) { int v; sscanf(s, "%2x", &v); return v; }

int main(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "mac")) {
        /* multiwan_ctl mac AA:BB:CC:DD:EE:FF <op>   op: 1=WAN1(5G) 2=WAN2(eth) 0=del */
        if (argc != 4) { fprintf(stderr, "usage: %s mac <aa:bb:cc:dd:ee:ff> <0|1|2>\n", argv[0]); return 1; }
        struct { unsigned char mac[6]; unsigned char pad[2]; unsigned int op; } m;
        memset(&m, 0, sizeof m);
        if (sscanf(argv[2], "%2x:%2x:%2x:%2x:%2x:%2x",
                   (unsigned*)&m.mac[0], (unsigned*)&m.mac[1], (unsigned*)&m.mac[2],
                   (unsigned*)&m.mac[3], (unsigned*)&m.mac[4], (unsigned*)&m.mac[5]) != 6) {
            fprintf(stderr, "bad mac\n"); return 1;
        }
        m.op = strtoul(argv[3], 0, 0);
        int rc = fhdrv_net_set_multiwan_mac_config(&m);
        printf("set_mac_config rc=%d mac=%02x:%02x:%02x:%02x:%02x:%02x op=%u\n",
               rc, m.mac[0],m.mac[1],m.mac[2],m.mac[3],m.mac[4],m.mac[5], m.op);
        return rc == 0 ? 0 : 4;
    }
    if (argc != 6) {
        fprintf(stderr, "usage: %s <enable> <w1_pct> <w2_pct> <s1> <s2>\n"
                        "       %s mac <aa:bb:cc:dd:ee:ff> <0|1|2>   (1=5G 2=eth 0=del)\n", argv[0], argv[0]);
        return 1;
    }
    struct mw m;
    memset(&m, 0, sizeof(m));
    m.enable      = strtoul(argv[1], 0, 0);
    m.wan1_mark   = 0x4000000;
    m.wan2_mark   = 0x8000000;
    m.wan1_mask   = 0xfc000000;
    m.wan2_mask   = 0xfc000000;
    m.wan1_percent= strtoul(argv[2], 0, 0);
    m.wan2_percent= strtoul(argv[3], 0, 0);
    m.wan1_status = strtoul(argv[4], 0, 0);
    m.wan2_status = strtoul(argv[5], 0, 0);

    int rc = fhdrv_net_set_multiwan_mode(&m);
    printf("set_multiwan_mode rc=%d enable=%u pct=%u/%u status=%u/%u\n",
           rc, m.enable, m.wan1_percent, m.wan2_percent, m.wan1_status, m.wan2_status);
    return rc == 0 ? 0 : 4;
}
