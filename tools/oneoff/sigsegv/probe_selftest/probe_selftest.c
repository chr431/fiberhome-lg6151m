/* probe_selftest.c -- positive controls for cth_pf / cth_cfu / uw_hook.
 *
 * This module is NOT a detector.  It deliberately triggers the three paths a
 * negative result depends on, so "0 hits" can be distinguished from "the probe
 * never worked".
 *
 * Usage:
 *   echo "pf 0x7fff...."  > /proc/probe_selftest   # copy_to_user to RO page
 *   echo "cfu 0x7fff...." > /proc/probe_selftest   # copy_from_user dst=user
 *   echo "uw 0x7fff...."  > /proc/probe_selftest   # hrtimer copy_to_user
 *
 * Expected with cth.ko loaded:
 *   pf  -> cth: PF#... far=<va> ... KERNEL ...
 *   cfu -> cth: CFU-MISUSE#... dst(user)=<va> ...
 *   uw  -> uw: HIT#... ENABLE site=... irq=1
 *
 * Build with the existing freestanding chain:
 *   tmpfiles/an4/build.sh probe_selftest
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/hrtimer.h>
#include <linux/ktime.h>

static char kbuf[32] = "PROBE_SELFTEST_32BYTES_PAYLOAD";
static unsigned long g_va;
static struct hrtimer g_timer;

static enum hrtimer_restart uw_cb(struct hrtimer *t)
{
    int rc;
    (void)t;
    rc = copy_to_user((void __user *)g_va, kbuf, 32);
    pr_info("probe_selftest: uw cb va=%#lx rc=%d in_interrupt=%d\n",
            g_va, rc, in_interrupt());
    return HRTIMER_NORESTART;
}

static ssize_t ps_write(struct file *f, const char __user *ubuf,
                        size_t n, loff_t *off)
{
    char buf[64];
    char mode[16];
    unsigned long va = 0;
    int rc;

    (void)f; (void)off;
    if (n >= sizeof(buf))
        n = sizeof(buf) - 1;
    if (copy_from_user(buf, ubuf, n))
        return -EFAULT;
    buf[n] = 0;
    if (sscanf(buf, "%15s %lx", mode, &va) != 2)
        return -EINVAL;

    if (!strcmp(mode, "pf")) {
        rc = copy_to_user((void __user *)va, kbuf, 32);
        pr_info("probe_selftest: pf va=%#lx rc=%d\n", va, rc);
    } else if (!strcmp(mode, "cfu")) {
        rc = copy_from_user((void __user *)va, kbuf, 32);
        pr_info("probe_selftest: cfu va=%#lx rc=%d\n", va, rc);
    } else if (!strcmp(mode, "uw")) {
        g_va = va;
        hrtimer_init(&g_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
        g_timer.function = uw_cb;
        hrtimer_start(&g_timer, ms_to_ktime(10), HRTIMER_MODE_REL);
        pr_info("probe_selftest: uw armed va=%#lx\n", va);
    } else {
        return -EINVAL;
    }
    return n;
}

static const struct proc_ops ps_ops = {
    .proc_write = ps_write,
};

static int __init ps_init(void)
{
    proc_create("probe_selftest", 0200, NULL, &ps_ops);
    pr_info("probe_selftest: ready\n");
    return 0;
}

static void __exit ps_exit(void)
{
    hrtimer_cancel(&g_timer);
    remove_proc_entry("probe_selftest", NULL);
    pr_info("probe_selftest: exit\n");
}

module_init(ps_init);
module_exit(ps_exit);
MODULE_LICENSE("GPL");
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
