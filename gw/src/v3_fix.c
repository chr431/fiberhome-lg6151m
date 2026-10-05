// SPDX-License-Identifier: GPL-2.0
// v3_fix.ko -- two de-FH enablers for the LG6151M v3 firmware (5.15.134 aarch64)
//
// 1) TTL masquerade: netfilter POST_ROUTING hook that rewrites IPv4 TTL on
//    egress so traffic routed by the CPE looks single-homed:
//      ttl_mode=1 (default): ttl++ (undo the routing decrement, keep per-OS value)
//      ttl_mode=2          : ttl=64 (look like one Linux host)
//      ttl_mode=0          : off
//    Only fires on state->out == wan_if (default eth1; set wan_if="" for all).
//
// 2) RX unhook: NULLs the two Quectel/FH interception slots in vmlinux
//    (ppe_hook_rx_eth set by hw_nat.ko, quec_eth_rx_hook set by fhdrv_eth_drv.ko)
//    so mtk_poll_rx delivers 100% stock frames to the stack. unhook=0 disables.
//
// Build (zig cc, no kbuild): see tools/build_v3fix.sh
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/ip.h>
#include <linux/skbuff.h>
#include <linux/netdevice.h>
#include <linux/if_ether.h>
#include <linux/string.h>
#include <linux/io.h>
#include <linux/ioport.h>

#include <linux/version.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("v3 TTL masquerade + RX unhook (de-FH LG6151M)");
MODULE_AUTHOR("chr431");

static char *wan_if = "eth1";
module_param(wan_if, charp, 0644);
MODULE_PARM_DESC(wan_if, "comma-separated egress netdev names for TTL rewrite (\"\" = all)");

/* match state->out->name against the comma-separated wan_if list */
static int wan_match(const char *name)
{
    const char *p = wan_if;
    size_t nl = strlen(name);
    if (!wan_if[0])
        return 1;
    while (*p) {
        const char *c = p;
        size_t cl;
        while (*c && *c != ',')
            c++;
        cl = c - p;
        if (cl == nl && memcmp(p, name, nl) == 0)
            return 1;
        p = *c ? c + 1 : c;
    }
    return 0;
}

static int ttl_mode = 1;
module_param(ttl_mode, int, 0644);
MODULE_PARM_DESC(ttl_mode, "0=off 1=ttl+1 (undo decrement) 2=ttl=64");

static int unhook = 1;
module_param(unhook, int, 0644);
MODULE_PARM_DESC(unhook, "1 = clear ppe_hook_rx_eth/quec_eth_rx_hook slots");

/* hook slots exported by the FH vmlinux (see analysis/rx_ev/RX_PATH_REPORT.md) */
extern void *ppe_hook_rx_eth;
extern void *quec_eth_rx_hook;

static void *saved_ppe_hook, *saved_quec_hook;

/* direct GDM FWD_CFG poke: gdm_off/gdm_val (hex offsets from FE 0x15100000).
 * Kernel iowrite bypasses the proc-write protection seen from userspace. */
static int gdm_off, gdm_val;
module_param(gdm_off, int, 0444);
module_param(gdm_val, int, 0444);
MODULE_PARM_DESC(gdm_off, "FE register offset to poke (e.g. 0x1500=5376)");
MODULE_PARM_DESC(gdm_val, "value to write (e.g. 0xc0713333)");

static unsigned int ttl_fix_fn(void *priv, struct sk_buff *skb,
                               const struct nf_hook_state *state)
{
    struct iphdr *iph;
    __u16 old_ttl;

    if (ttl_mode == 0)
        return NF_ACCEPT;
    if (state->out && !wan_match(state->out->name))
        return NF_ACCEPT;
    if (!pskb_may_pull(skb, sizeof(struct iphdr)))
        return NF_ACCEPT;
    iph = ip_hdr(skb);
    if (iph->version != 4 || iph->ihl < 5)
        return NF_ACCEPT;
    old_ttl = iph->ttl;
    if (ttl_mode == 1) {
        if (old_ttl < 2)           /* let dying packets die, keep traceroute sane */
            return NF_ACCEPT;
        iph->ttl = old_ttl + 1;
    } else {
        iph->ttl = 64;
    }
    /* recompute the full header checksum (20 bytes, cheap, unambiguous) */
    {
        __u32 sum = 0;
        __u16 *p = (__u16 *)iph;
        int n = iph->ihl * 2;
        iph->check = 0;
        while (n--) sum += *p++;
        sum = (sum & 0xffff) + (sum >> 16);
        sum = (sum & 0xffff) + (sum >> 16);
        iph->check = ~sum;
    }
    return NF_ACCEPT;
}

static struct nf_hook_ops ttl_hook_ops = {
    .hook     = ttl_fix_fn,
    .pf       = NFPROTO_IPV4,
    .hooknum  = NF_INET_POST_ROUTING,
    .priority = NF_IP_PRI_LAST - 10,   /* after NAT src / mangle, before confirm */
};

static int __init v3fix_init(void)
{
    int ret;

    if (gdm_off) {
        void __iomem *fe = ioremap(0x15100000ULL + (gdm_off & ~0xfff), 0x1000);
        if (fe) {
            writel((u32)gdm_val, fe + (gdm_off & 0xfff));
            pr_info("v3_fix: poked FE+%#x = %#x (readback %#x)\n",
                    gdm_off, (u32)gdm_val, readl(fe + (gdm_off & 0xfff)));
            iounmap(fe);
        } else {
            pr_err("v3_fix: ioremap FE failed\n");
        }
    }

    if (ttl_mode) {
        ret = nf_register_net_hook(&init_net, &ttl_hook_ops);
        if (ret) {
            pr_err("v3_fix: ttl hook register failed %d\n", ret);
            return ret;
        }
        pr_info("v3_fix: TTL mode %d on egress '%s'\n", ttl_mode,
                wan_if[0] ? wan_if : "<all>");
    }
    if (unhook) {
        saved_ppe_hook  = xchg(&ppe_hook_rx_eth, NULL);
        saved_quec_hook = xchg(&quec_eth_rx_hook, NULL);
        pr_info("v3_fix: RX hooks cleared (ppe=%px quec=%px)\n",
                saved_ppe_hook, saved_quec_hook);
    }
    return 0;
}

static void __exit v3fix_exit(void)
{
    if (ttl_mode)
        nf_unregister_net_hook(&init_net, &ttl_hook_ops);
    if (saved_ppe_hook)
        ppe_hook_rx_eth = saved_ppe_hook;
    if (saved_quec_hook)
        quec_eth_rx_hook = saved_quec_hook;
    pr_info("v3_fix: unloaded\n");
}

/* arm64 kernel modules on this vendor tree must ship .plt/.init.plt sections
 * (GNU ld -r emits 8-byte ones; lld does not). The loader re-sizes/fills them. */
static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(v3fix_init);
module_exit(v3fix_exit);

/* --- modpost-equivalent (normally generated as <mod>.mod.c by kbuild) --- */
MODULE_INFO(vermagic, "5.15.134 SMP mod_unload aarch64");
MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};
