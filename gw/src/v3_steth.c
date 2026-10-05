// SPDX-License-Identifier: GPL-2.0
// v3_steth.ko — kernel stethoscope: FH hook-slot watchdog + wifi TX-stall detector.
//
// Purpose (2026-10-02): stop GUESSING about two unexplained mechanisms:
//   1. Who arms/disarms FH interception slots at runtime (the BA-quirk hunt
//      needed hours of indirect evidence; ppe_hook_rx_eth 0x112f9e8,
//      quec_eth_rx_hook 0x11166c8, g_fhdrv_eth_tx_hook 0x11270b0,
//      br fwd slots 0x112f8f0/8f8 — corpus VAs, calibrated runtime bias
//      0x08110000 verified on 3 symbols 2026-10-02).
//      -> sample every tick, printk ONLY on change (old -> new).
//   2. The "TCP dies, ICMP lives" wifi quirk: per-radio TX-stall episodes
//      (rx strictly advancing while tx frozen and iface RUNNING) logged with
//      timestamps + exposed via /proc/v3_steth for wifi_guard.sh to act on.
//
// Observe-only by design: never modifies hooks, never bounces ifaces.
// Build: tools/build_steth.sh (zig cc, same chain as healthdog).
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/timer.h>
#include <linux/jiffies.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/netdevice.h>
#include <linux/string.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("v3 stethoscope: FH hook-slot watchdog + wifi TX-stall detector");

static ulong bias = 0x08110000;
module_param(bias, ulong, 0444);
MODULE_PARM_DESC(bias, "corpus->runtime VA bias (calibrated 0x08110000)");

static int interval_s = 5;
module_param(interval_s, int, 0644);
MODULE_PARM_DESC(interval_s, "sample period seconds (default 5)");

#define NSLOTS 5
static const struct { const char *name; ulong corpus_va; } slots[NSLOTS] = {
	{ "ppe_hook_rx_eth",     0x112f9e8 },
	{ "quec_eth_rx_hook",    0x11166c8 },
	{ "g_fhdrv_eth_tx_hook", 0x11270b0 },
	{ "br_fwd_slot_0",       0x112f8f0 },
	{ "br_fwd_slot_1",       0x112f8f8 },
};
static ulong slot_val[NSLOTS];      /* last read */
static ulong slot_changes[NSLOTS];  /* change count per slot */

#define NIF 2
static const char *ifnames[NIF] = { "ra0", "rai0" };
struct ifwatch {
	unsigned long rx[3], tx[3];   /* rolling samples, [2] newest */
	int have;
	int stall;
	unsigned long episodes;
	unsigned long ep_start;       /* jiffies */
	unsigned long last_rx, last_tx;
};
static struct ifwatch ifw[NIF];

static struct timer_list st_timer;

static ulong slot_read(int i)
{
	ulong *addr = (ulong *)(0xffffffc000000000UL + bias + slots[i].corpus_va);
	return *addr;
}

static void if_sample(struct ifwatch *w, struct net_device *dev)
{
	/* dev->stats is NOT maintained by mt_wifi (stays 0) — real counters live
	 * behind ndo_get_stats64; dev_get_stats() dispatches correctly. */
	struct rtnl_link_stats64 s;
	unsigned long rx, tx;

	dev_get_stats(dev, &s);
	rx = s.rx_packets; tx = s.tx_packets;

	w->rx[0] = w->rx[1]; w->rx[1] = w->rx[2]; w->rx[2] = rx;
	w->tx[0] = w->tx[1]; w->tx[1] = w->tx[2]; w->tx[2] = tx;
	if (!w->have) { w->have = 1; w->last_rx = rx; w->last_tx = tx; return; }
	w->last_rx = rx; w->last_tx = tx;
	if (w->have < 3) { w->have++; return; }

	int stalled = (w->rx[2] - w->rx[0] >= 3) && (w->tx[0] == w->tx[2]) &&
		      netif_running(dev) && netif_carrier_ok(dev);
	if (stalled && !w->stall) {
		w->stall = 1; w->episodes++; w->ep_start = jiffies;
		pr_info("STETH TX-STALL START %s: rx %lu->%lu advancing, tx frozen at %lu\n",
			dev->name, w->rx[0], w->rx[2], w->tx[2]);
	} else if (!stalled && w->stall) {
		w->stall = 0;
		pr_info("STETH TX-STALL END %s after %lus: tx now %lu (rx %lu)\n",
			dev->name, (jiffies - w->ep_start) / HZ, w->tx[2], w->rx[2]);
	}
}

static void st_tick(struct timer_list *t)
{
	int i;

	for (i = 0; i < NSLOTS; i++) {
		ulong v = slot_read(i);
		if (v != slot_val[i]) {
			pr_info("STETH slot %s: 0x%016lx -> 0x%016lx\n",
				slots[i].name, slot_val[i], v);
			slot_val[i] = v;
			slot_changes[i]++;
		}
	}
	for (i = 0; i < NIF; i++) {
		struct net_device *dev = dev_get_by_name(&init_net, ifnames[i]);
		if (dev) {
			if_sample(&ifw[i], dev);
			dev_put(dev);
		}
	}
	mod_timer(&st_timer, jiffies + (unsigned long)interval_s * HZ);
}

static int st_show(struct seq_file *m, void *v)
{
	int i;
	seq_printf(m, "bias=0x%lx interval=%ds uptime_ticks=%lu\n", bias, interval_s, jiffies / HZ);
	for (i = 0; i < NSLOTS; i++)
		seq_printf(m, "slot %-20s = 0x%016lx changes=%lu\n",
			   slots[i].name, slot_val[i], slot_changes[i]);
	for (i = 0; i < NIF; i++)
		seq_printf(m, "if %-6s rx=%lu tx=%lu stall=%d episodes=%lu\n",
			   ifnames[i], ifw[i].last_rx, ifw[i].last_tx,
			   ifw[i].stall, ifw[i].episodes);
	return 0;
}

static int st_open(struct inode *ino, struct file *f) { return single_open(f, st_show, NULL); }

static const struct proc_ops st_ops = {
	.proc_open = st_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int __init steth_init(void)
{
	int i;
	for (i = 0; i < NSLOTS; i++)
		slot_val[i] = slot_read(i);
	proc_create("v3_steth", 0444, NULL, &st_ops);
	timer_setup(&st_timer, st_tick, 0);
	mod_timer(&st_timer, jiffies + HZ);
	pr_info("v3_steth: loaded bias=0x%lx slots baselined\n", bias);
	for (i = 0; i < NSLOTS; i++)
		pr_info("v3_steth: slot %-20s = 0x%016lx\n", slots[i].name, slot_val[i]);
	return 0;
}

static void __exit steth_exit(void)
{
	del_timer_sync(&st_timer);
	remove_proc_entry("v3_steth", NULL);
	pr_info("v3_steth: unloaded\n");
}

module_init(steth_init);
module_exit(steth_exit);

/* --- modpost-equivalent + vendor PLT sections (same as healthdog) --- */
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

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};
