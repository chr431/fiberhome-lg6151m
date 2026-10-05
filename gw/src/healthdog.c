// SPDX-License-Identifier: GPL-2.0
// healthdog.ko — kernel-side liveness monitor with wedge-proof HW reset.
//
// Problem (2026-10-01): userspace wedges (FH br_del_if deadlock, rmmod hang)
// leave the kernel alive — the mtk wdtk threads keep petting the RGU watchdog
// by CPU liveness, so nothing ever resets the box; serial SysRq is dead on
// this platform; manual power-cycle was the only out.
//
// Design: userspace healthdog.sh pets /proc/healthdog only while the system
// is healthy (fork works + local TCP/SSH answers). This module re-checks from
// a kernel timer (softirq context — survives userspace D-state storms; the
// nomaster-wedge still ran timers, proven by live serial echo). If armed and
// the heartbeat goes stale > timeout, call emergency_restart() — the exact
// path sysrq-b uses on this box (verified twice 2026-10-01).
//
// Safety: armed=0 by default; userspace only arms it when the marker file
// /data/gw/healthdog.armed exists. disarm anytime: echo disarm > node.
// Build: tools/build_healthdog.sh (zig cc, aarch64-freestanding, no kbuild).
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/timer.h>
#include <linux/jiffies.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/seq_file.h>
#include <linux/reboot.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/string.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("kernel healthdog: heartbeat monitor + wedge-proof reset");

static int armed;
module_param(armed, int, 0644);
MODULE_PARM_DESC(armed, "1 = enforce heartbeat timeout");

static int timeout_s = 90;
module_param(timeout_s, int, 0644);
MODULE_PARM_DESC(timeout_s, "heartbeat timeout in seconds (default 90)");

static int forensic;
module_param(forensic, int, 0444);
MODULE_PARM_DESC(forensic, "1 = dump D-state procs via printk every 20s");

static unsigned long last_hb;
static unsigned long fore_ticks;
static struct timer_list hd_timer;
static unsigned long hb_count, timeouts;

static void hd_fire(struct timer_list *t)
{
	if (forensic) {
		fore_ticks++;
		if (fore_ticks % 4 == 0) {
			struct task_struct *p;
			rcu_read_lock();
			for_each_process(p) {
				if (p->__state == TASK_UNINTERRUPTIBLE)
					pr_info("FORENSIC D: pid=%d comm=%s\n", p->pid, p->comm);
			}
			rcu_read_unlock();
		}
	}
	if (armed && time_after(jiffies, last_hb + (unsigned long)timeout_s * HZ)) {
		pr_emerg("healthdog: heartbeat stale >%ds (hbs=%lu) — EMERGENCY RESTART\n",
			 timeout_s, hb_count);
		emergency_restart();
		return; /* never reached on success */
	}
	mod_timer(&hd_timer, jiffies + 5 * HZ);
}

static ssize_t hd_write(struct file *f, const char __user *buf, size_t n, loff_t *off)
{
	char kbuf[16];
	size_t c = n < 15 ? n : 15;

	if (copy_from_user(kbuf, buf, c))
		return -EFAULT;
	kbuf[c] = 0;
	if (strncmp(kbuf, "disarm", 6) == 0) {
		armed = 0;
		pr_info("healthdog: disarmed\n");
	} else if (strncmp(kbuf, "arm", 3) == 0) {
		armed = 1;
		last_hb = jiffies;
		pr_info("healthdog: ARMED (timeout %ds)\n", timeout_s);
	} else {
		last_hb = jiffies; /* heartbeat */
		hb_count++;
	}
	return n;
}

static int hd_show(struct seq_file *m, void *v)
{
	unsigned long age = (jiffies - last_hb) / HZ;
	seq_printf(m, "armed=%d timeout_s=%d heartbeat_age_s=%lu heartbeats=%lu firings=%lu\n",
		   armed, timeout_s, armed ? age : 0, hb_count, timeouts);
	return 0;
}

static int hd_open(struct inode *i, struct file *f) { return single_open(f, hd_show, NULL); }

static const struct proc_ops hd_ops = {
	.proc_open = hd_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_write = hd_write,
	.proc_release = single_release,
};

static int __init healthdog_init(void)
{
	proc_create("healthdog", 0666, NULL, &hd_ops);
	last_hb = jiffies;
	timer_setup(&hd_timer, hd_fire, 0);
	mod_timer(&hd_timer, jiffies + 5 * HZ);
	pr_info("healthdog: loaded (armed=%d timeout=%ds)\n", armed, timeout_s);
	return 0;
}

static void __exit healthdog_exit(void)
{
	armed = 0;
	del_timer_sync(&hd_timer);
	remove_proc_entry("healthdog", NULL);
	pr_info("healthdog: unloaded\n");
}

module_init(healthdog_init);
module_exit(healthdog_exit);

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

/* arm64 vendor loader requires shipped .plt/.init.plt sections */
static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};
