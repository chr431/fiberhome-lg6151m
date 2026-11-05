// sramrd.c -- U-G3: read-only on-SoC SRAM dumper (medmcu scp_sram, sspm_base).
// SRAM = memory-class (not registers) -> no read-to-clear risk expected.
// STILL: read-only, single-shot per cat, no repeated polling of unknown regions.
//   echo "<hexaddr> <len> [off]" > /proc/sramrd ; cat /proc/sramrd
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/io.h>

MODULE_LICENSE("GPL");

static unsigned long g_addr, g_len = 0x100, g_off;
static u8 g_buf[0x1000];

static ssize_t sr_write(struct file *f, const char __user *ub, size_t n, loff_t *off)
{
	char buf[80];
	unsigned long a, l = 0x100, o = 0;
	if (n >= sizeof(buf)) return -EINVAL;
	if (copy_from_user(buf, ub, n)) return -EFAULT;
	buf[n] = 0;
	if (sscanf(buf, "%lx %lx %lx", &a, &l, &o) < 1) return -EINVAL;
	if (l == 0 || l > 0x1000) l = 0x1000;
	g_addr = a; g_len = l; g_off = o;
	return n;
}

static int sr_show(struct seq_file *s, void *v)
{
	void __iomem *m;
	int i;
	if (!g_addr) return 0;
	m = ioremap(g_addr, g_off + g_len);
	if (!m) { seq_printf(s, "ioremap failed\n"); return 0; }
	memcpy_fromio(g_buf, m + g_off, g_len);
	iounmap(m);
	seq_printf(s, "sramrd %08lx+%lx off=%lx\n", g_addr, g_len, g_off);
	for (i = 0; i < (int)g_len; i += 32) {
		int j;
		seq_printf(s, "  %04x:", i);
		for (j = 0; j < 32; j++) seq_printf(s, " %02x", g_buf[i + j]);
		seq_printf(s, "\n");
	}
	return 0;
}

static int sr_open(struct inode *i, struct file *f) { return single_open(f, sr_show, NULL); }
static const struct proc_ops sr_ops = { .proc_open = sr_open, .proc_read = seq_read, .proc_lseek = seq_lseek, .proc_release = single_release, .proc_write = sr_write };

static int __init sr_init(void) { proc_create("sramrd", 0644, NULL, &sr_ops); pr_info("sramrd: loaded\n"); return 0; }
static void __exit sr_exit(void) { remove_proc_entry("sramrd", NULL); pr_info("sramrd: unloaded\n"); }
module_init(sr_init);
module_exit(sr_exit);

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
