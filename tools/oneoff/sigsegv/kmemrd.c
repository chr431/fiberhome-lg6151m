// kmemrd.c -- U-G3: generic kernel-memory qword reader (read-only).
//   echo "<hexaddr> [nq]" > /proc/kmemrd ; cat /proc/kmemrd
// Pure kernel VA reads. No MMIO. For walking live driver structs (hw_nat foe base etc).
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>

MODULE_LICENSE("GPL");

static unsigned long g_addr;
static int g_nq = 8;

static ssize_t kr_write(struct file *f, const char __user *ub, size_t n, loff_t *off)
{
	char buf[64];
	unsigned long a;
	int q = 8;
	if (n >= sizeof(buf)) return -EINVAL;
	if (copy_from_user(buf, ub, n)) return -EFAULT;
	buf[n] = 0;
	if (sscanf(buf, "%lx %d", &a, &q) < 1) return -EINVAL;
	if (a < 0xffffff0000000000UL) return -EINVAL;
	g_addr = a; g_nq = q < 1 ? 1 : (q > 4096 ? 4096 : q);
	return n;
}

static int kr_show(struct seq_file *s, void *v)
{
	int i;
	u64 val;
	seq_printf(s, "kmemrd %016lx nq=%d\n", g_addr, g_nq);
	if (!g_addr) return 0;
	for (i = 0; i < g_nq; i++) {
		val = *(volatile u64 *)(g_addr + 8UL * i);
		if ((i & 3) == 0) seq_printf(s, "  +%04x:", i * 8);
		seq_printf(s, " %016llx", (unsigned long long)val);
		if ((i & 3) == 3) seq_printf(s, "\n");
	}
	if (g_nq & 3) seq_printf(s, "\n");
	return 0;
}

static int kr_open(struct inode *i, struct file *f) { return single_open(f, kr_show, NULL); }
static const struct proc_ops kr_ops = { .proc_open = kr_open, .proc_read = seq_read, .proc_lseek = seq_lseek, .proc_release = single_release, .proc_write = kr_write };

static int __init kr_init(void)
{
	proc_create("kmemrd", 0644, NULL, &kr_ops);
	pr_info("kmemrd: loaded\n");
	return 0;
}
static void __exit kr_exit(void) { remove_proc_entry("kmemrd", NULL); pr_info("kmemrd: unloaded\n"); }
module_init(kr_init);
module_exit(kr_exit);

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
