// ringdump.c -- U-G3: dump DMA ring base PAs of the ACTIVE mtk_eth driver
// and the idle netsys-edma framework, by walking kernel globals.
// Pure kernel-DRAM reads only. No MMIO. No locks (pointers are stable post-probe).
//   globals (vmlinux, no-KASLR verified live):
//     0xffffffc009226be0 -> g_mac_dev (struct mac_dev*)  ; priv = *(g_mac_dev+0)
//       rx ring structs: priv+0xa40 / 0xa70 / 0xaa0 (rx_ring1/2/3_read)
//     0xffffffc009225a38 -> fe_edma priv (struct fe_edma*, 0x3b8 bytes)
// proc: cat /proc/ringdump
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/kernel.h>

MODULE_LICENSE("GPL");

#define G_ETH_SLOT      0xffffffc009226758UL   /* struct mtk_eth* (tx_ring_read/rx_ring_read) */
#define FE_EDMA_SLOT   0xffffffc009225a38UL

static void dump_qwords(struct seq_file *s, const char *tag, u64 base, int nq)
{
	int i;
	u64 v;
	if (!base || base < 0xffffff0000000000UL) {
		seq_printf(s, "%s base=%llx INVALID\n", tag, base);
		return;
	}
	seq_printf(s, "%s base=%llx\n", tag, base);
	for (i = 0; i < nq; i++) {
		v = *(volatile u64 *)(base + 8UL * i);
		if ((i & 3) == 0)
			seq_printf(s, "  +%03x:", i * 8);
		seq_printf(s, " %016llx", v);
		if ((i & 3) == 3)
			seq_printf(s, "\n");
	}
	if (nq & 3) seq_printf(s, "\n");
}

static int rd_show(struct seq_file *s, void *v)
{
	u64 g, pa, pb, ringva;
	int i;

	g = *(volatile u64 *)G_ETH_SLOT;
	seq_printf(s, "mtk_eth=%llx\n", g);
	if (g >= 0xffffff0000000000UL) {
		dump_qwords(s, "eth[0x980..0xc00)", g + 0x980, (0xc00 - 0x980) / 8);
		/* tx_ring @ +0x9c0, rx_ring[i] @ +0xa10+i*0x30 */
		ringva = *(volatile u64 *)(g + 0x9c0);
		dump_qwords(s, "txring", ringva, 8);
		for (i = 0; i < 4; i++) {
			ringva = *(volatile u64 *)(g + 0xa10 + 0x30UL * i);
			dump_qwords(s, "rxring", ringva, 8);
		}
	}
	pb = *(volatile u64 *)FE_EDMA_SLOT;
	seq_printf(s, "fe_edma_priv=%llx\n", pb);
	if (pb >= 0xffffff0000000000UL) {
		dump_qwords(s, "privB[0..0x3b8)", pb, 0x3b8 / 8);
		for (i = 0; i < 3; i++) {
			u64 fe = *(volatile u64 *)(pb + 0x398 + 8UL * i);
			dump_qwords(s, "feN", fe, 6);
		}
	}
	return 0;
}

static int rd_open(struct inode *i, struct file *f)
{
	return single_open(f, rd_show, NULL);
}
static const struct proc_ops rd_ops = { .proc_open = rd_open, .proc_read = seq_read, .proc_lseek = seq_lseek, .proc_release = single_release };

static int __init rd_init(void)
{
	proc_create("ringdump", 0444, NULL, &rd_ops);
	pr_info("ringdump: loaded\n");
	return 0;
}
static void __exit rd_exit(void)
{
	remove_proc_entry("ringdump", NULL);
	pr_info("ringdump: unloaded\n");
}
module_init(rd_init);
module_exit(rd_exit);

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

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
