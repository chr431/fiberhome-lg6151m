// SPDX-License-Identifier: GPL-2.0
// rxring.ko -- high-frequency DD=1 sampler for the MTK EDMA RX ring.
//
//   insmod rxring.ko ring_va=0xffffff801a47c000 ring_entries=512
//   cat /proc/rxring        -> counters + last captured entries
//   echo 0 > /proc/rxring   -> stop sampling
//
// Read-only: only loads from the linear-mapped ring. ring_va must come from
// /proc/mtkfe/dump_dma (changes every boot). Default arm=0 (no sampling).
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>
#include <linux/slab.h>
#include <linux/version.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("rxring: DD=1 sampler for MTK EDMA RX ring");
MODULE_AUTHOR("chr431");

static unsigned long ring_va;
module_param(ring_va, ulong, 0444);
MODULE_PARM_DESC(ring_va, "linear-map VA of the EDMA RX ring (from /proc/mtkfe/dump_dma)");

static int ring_entries = 512;
module_param(ring_entries, int, 0444);
MODULE_PARM_DESC(ring_entries, "number of 32B descriptors in the ring");

#define MAXREC 64
struct rec { u32 idx; u32 w0, w1, w2, w3; u64 ns; };

static struct rec recs[MAXREC];
static int nrec;
static u64 scans, dd_seen, total_dd;
static int arm = 1;
static struct task_struct *th;

static int sampler(void *unused)
{
    while (!kthread_should_stop()) {
        if (arm && ring_va) {
            const u32 *p = (const u32 *)ring_va;
            int i;
            scans++;
            for (i = 0; i < ring_entries; i++) {
                const u32 *e = p + i * 8;
                u32 w1 = e[1];
                if (w1 & 0x80000000u) {           /* DD bit */
                    dd_seen++;
                    total_dd++;
                    if (nrec < MAXREC) {
                        recs[nrec].idx = i;
                        recs[nrec].w0 = e[0];
                        recs[nrec].w1 = w1;
                        recs[nrec].w2 = e[2];
                        recs[nrec].w3 = e[3];
                        recs[nrec].ns = ktime_get_ns();
                        nrec++;
                    }
                }
            }
        }
        usleep_range(200, 400);
    }
    return 0;
}

static ssize_t rr_read(struct file *f, char __user *ubuf, size_t len, loff_t *off)
{
    char *buf = kzalloc(4096, GFP_KERNEL);
    int n = 0, i, ret;
    if (!buf) return -ENOMEM;
    n += scnprintf(buf + n, 4096 - n, "ring_va=0x%lx entries=%d scans=%llu dd_total=%llu captured=%d arm=%d\n",
                   ring_va, ring_entries, scans, total_dd, nrec, arm);
    for (i = 0; i < nrec && n < 3600; i++)
        n += scnprintf(buf + n, 4096 - n, "rec %d idx=%u w0=%08x w1=%08x w2=%08x w3=%08x ns=%llu\n",
                       i, recs[i].idx, recs[i].w0, recs[i].w1, recs[i].w2, recs[i].w3, recs[i].ns);
    if (*off >= n) { kfree(buf); return 0; }
    if ((size_t)(n - *off) > len) n = *off + len;
    ret = copy_to_user(ubuf, buf + *off, n - *off);
    if (ret) { kfree(buf); return -EFAULT; }
    ret = n - *off;
    *off = n;
    kfree(buf);
    return ret;
}

static ssize_t rr_write(struct file *f, const char __user *ubuf, size_t len, loff_t *off)
{
    char kbuf[16];
    int v;
    if (len == 0 || len >= sizeof(kbuf)) return -EINVAL;
    if (copy_from_user(kbuf, ubuf, len)) return -EFAULT;
    kbuf[len] = 0;
    if (sscanf(kbuf, "%d", &v) != 1) return -EINVAL;
    arm = v ? 1 : 0;
    if (!arm) { nrec = 0; }
    return len;
}

static const struct proc_ops rr_ops = { .proc_read = rr_read, .proc_write = rr_write };
static struct proc_dir_entry *pe;

static int __init rxring_init(void)
{
    unsigned long pa;
    if (!ring_va) {
        pr_info("rxring: ring_va not set, disabled\n");
        return -EINVAL;
    }
    if ((ring_va >> 40) != 0xffffffUL) {
        pr_info("rxring: ring_va 0x%lx does not look like a linear-map address\n", ring_va);
        return -EINVAL;
    }
    pa = virt_to_phys((void *)ring_va);
    pr_info("rxring: ring_va=0x%lx pa=0x%lx entries=%d\n", ring_va, pa, ring_entries);
    th = kthread_run(sampler, NULL, "rxring");
    if (IS_ERR(th)) { th = NULL; return -ENOMEM; }
    pe = proc_create("rxring", 0644, NULL, &rr_ops);
    if (!pe) { kthread_stop(th); th = NULL; return -ENOMEM; }
    pr_info("rxring: loaded\n");
    return 0;
}

static void __exit rxring_exit(void)
{
    if (pe) proc_remove(pe);
    if (th) kthread_stop(th);
    pr_info("rxring: unloaded (scans=%llu dd=%llu)\n", scans, total_dd);
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(rxring_init);
module_exit(rxring_exit);

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
