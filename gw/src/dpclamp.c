// SPDX-License-Identifier: GPL-2.0
// dpclamp.ko -- drain the MD's accumulated stale-page list out of circulation.
//
// Complement to dpquar (which stops NEW pages entering the MD stale list at
// dpmaif teardown).  The list accumulated by every free that happened before
// dpquar (thousands of pages) persists MD-side, survives MD warm reset, and
// its members keep cycling through buddy/user/kernel -- that is the active
// injection source observed on 2026-10-22 (buddyscan: ~400-page fixed set,
// members re-hit up to 113x/6min).
//
// Key trick: a listed page self-identifies the moment the allocator hands it
// out -- it still carries the injection record (word 504/505, page otherwise
// zero).  So: periodically allocate order-0 pages in batches, test each for
// the signature, KEEP the signed ones (extra ref -> they never circulate
// again), free the rest.  Over a few passes every listed page that transits
// buddy gets clamped; MD's writes then land only on held (harmless) pages.
// Writer-hit telemetry (tail digest change on held pages) proves the
// mechanism live.
//
// usage: insmod dpclamp.ko [period_s=30] [batch=512] [cap=8192] [minfree_kb=100000]
//        cat /proc/dpclamp
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/moduleparam.h>
#include <linux/mm.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/jiffies.h>
#include <linux/slab.h>
#include <linux/proc_fs.h>
#include <linux/workqueue.h>
#include <linux/spinlock.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dpclamp: clamp MD-stale-listed pages out of circulation");

static int period_s = 15;
static int batch = 1024;
static int cap = 8192;			/* 32MB max held */
static int minfree_kb = 150000;		/* stop draining below this MemFree (kB) */

module_param_named(period_s, period_s, int, 0444);
module_param_named(batch, batch, int, 0444);
module_param_named(cap, cap, int, 0444);
module_param_named(minfree_kb, minfree_kb, int, 0444);

struct cent {
	struct page *page;
	unsigned long pa;
	u64 tail;
	unsigned long j;
};

static struct cent *ctab;
static int ccount;
static DEFINE_SPINLOCK(c_lock);

static u64 sweeps, alloced, clamped, freed_ok;
static u64 whits;
static int idle_sweeps;		/* adaptive cool-down (v1.2) */

static int tail_signature(const u64 *t)
{
	int at0 = t[0] && !t[1] && t[0] < 0x40000UL;
	int at1 = !at0 && t[1] && !t[2] && t[1] < 0x40000UL;
	int k, other = 0;

	if (!at0 && !at1)
		return 0;
	for (k = 0; k < 8; k++) {
		if (k < 3)
			continue;
		if (t[k])
			other++;
	}
	return other <= 1;
}

static u64 tail_digest(struct page *pg)
{
	u64 t[8];

	if (copy_from_kernel_nofault(t, page_address(pg) + (PAGE_SIZE - 64), 64))
		return 0;
	return t[0] ^ t[1] ^ t[2] ^ t[3] ^ t[4] ^ t[5] ^ t[6] ^ t[7];
}

static int test_and_hold(struct page *pg)
{
	u64 t[8];
	unsigned long pa;
	int i;

	if (copy_from_kernel_nofault(t, page_address(pg) + (PAGE_SIZE - 64), 64))
		return 0;
	if (!tail_signature(t))
		return 0;
	pa = (unsigned long)page_to_pfn(pg) << PAGE_SHIFT;
	spin_lock(&c_lock);
	for (i = 0; i < ccount; i++)
		if (ctab[i].pa == pa) {
			spin_unlock(&c_lock);
			return 0;	/* already held (shouldn't happen) */
		}
	if (ccount >= cap) {
		spin_unlock(&c_lock);
		return 0;
	}
	get_page(pg);		/* caller drops its own ref: page stays ours */
	ctab[ccount].page = pg;
	ctab[ccount].pa = pa;
	ctab[ccount].tail = t[0] ^ t[1] ^ t[2] ^ t[3] ^ t[3] ^ t[4] ^ t[5] ^ t[6] ^ t[7];
	ctab[ccount].j = jiffies;
	ccount++;
	clamped++;
	spin_unlock(&c_lock);
	return 1;
}

static void clamp_sweep(void)
{
	int i, nalloc = batch > 4096 ? 4096 : batch;
	int clamped_before = (int)clamped;

	if (si_mem_available() < minfree_kb)	/* kB */
		return;
	/* one page at a time -- the bulk array path oopsed in __free_pages
	 * (2026-10-22 21:33 KE, second reboot); keep it boring and provable */
	for (i = 0; i < nalloc; i++) {
		/* HIGHUSER_MOVABLE: the signed pages are ex-anon and live in
		 * the MOVABLE migrate lists; GFP_KERNEL never samples those
		 * (147k UNMOVABLE allocs: zero hits, buddyscan: ~47 signed
		 * pages per scan, 2026-10-22 21:42).
		 * __GFP_NORETRY: fail fast instead of compaction/reclaim
		 * storms -- the v1.1 fixed 4096-page/8s MOVABLE churn froze
		 * the box for ~25min and ended in an RCU-stall panic
		 * (2026-10-23 00:48 KE #3); a missed page transits buddy
		 * again and is caught by a later sweep. */
		struct page *pg = alloc_page(GFP_HIGHUSER_MOVABLE |
					     __GFP_NORETRY | __GFP_NOWARN);

		if (!pg)
			break;
		alloced++;
		if (test_and_hold(pg)) {
			freed_ok++;	/* kept */
			continue;
		}
		__free_page(pg);
		if ((i & 0x3f) == 0x3f)
			cond_resched();
	}
	sweeps++;
	/* adaptive cool-down: sweeps that clamp nothing back the poll off;
	 * any new clamp snaps back to the fast period */
	if ((int)clamped > clamped_before)
		idle_sweeps = 0;
	else if (idle_sweeps < 1000)
		idle_sweeps++;
}

static void dc_workfn(struct work_struct *w);
static DECLARE_DELAYED_WORK(dc_work, dc_workfn);

static void dc_workfn(struct work_struct *w)
{
	clamp_sweep();
	/* writer-hit watch on held pages (bounded sample per tick) */
	{
		int i, lim = ccount > 256 ? 256 : ccount;
		unsigned long fl;

		spin_lock_irqsave(&c_lock, fl);
		for (i = 0; i < lim; i++) {
			u64 d = tail_digest(ctab[i].page);

			if (d && d != ctab[i].tail) {
				ctab[i].tail = d;
				whits++;
			}
		}
		spin_unlock_irqrestore(&c_lock, fl);
	}
	{
		unsigned long p = (unsigned long)period_s;

		/* v1.2 adaptive ladder: fast only while actively clamping,
		 * then 2x period, then 60s patrol -- no sustained churn */
		if (p > 0) {
			if (idle_sweeps >= 3)
				p *= 2;
			if (idle_sweeps >= 10)
				p = 60;
			schedule_delayed_work(&dc_work, p * HZ);
		}
	}
}

/* ---------- proc ---------- */
static char pbuf[8192];
static int pbuf_len, pbuf_ready;

static ssize_t dc_read(struct file *f, char __user *ub, size_t n, loff_t *off)
{
	int len, chunk, r;
	unsigned long fl;

	if (pbuf_ready && *off >= pbuf_len)
		return 0;
	if (*off == 0) {
		spin_lock_irqsave(&c_lock, fl);
		len = scnprintf(pbuf, sizeof(pbuf),
			"dpclamp sweeps=%llu alloced=%llu clamped=%llu whits=%llu held=%d/%d idle=%d\n",
			sweeps, alloced, clamped, whits, ccount, cap, idle_sweeps);
		spin_unlock_irqrestore(&c_lock, fl);
		pbuf_len = len;
		pbuf_ready = 1;
	}
	chunk = pbuf_len - (int)*off;
	if (chunk <= 0)
		return 0;
	if (chunk > (int)n)
		chunk = (int)n;
	r = copy_to_user(ub, pbuf + *off, chunk);
	if (r)
		return -EFAULT;
	*off += chunk;
	if (*off >= pbuf_len)
		pbuf_ready = 0;
	return chunk;
}

static loff_t dc_lseek(struct file *f, loff_t off, int whence) { return 0; }

static const struct proc_ops dc_ops = {
	.proc_read = dc_read,
	.proc_lseek = dc_lseek,
};

static int __init dpclamp_init(void)
{
	ctab = kcalloc(cap, sizeof(*ctab), GFP_KERNEL);
	if (!ctab)
		return -ENOMEM;
	proc_create("dpclamp", 0666, NULL, &dc_ops);
	schedule_delayed_work(&dc_work, 0);
	pr_info("dpclamp: ready\n");
	return 0;
}

static void __exit dpclamp_exit(void)
{
	int i;

	cancel_delayed_work_sync(&dc_work);
	remove_proc_entry("dpclamp", NULL);
	spin_lock(&c_lock);
	for (i = 0; i < ccount; i++)
		put_page(ctab[i].page);
	ccount = 0;
	spin_unlock(&c_lock);
	kfree(ctab);
	pr_info("dpclamp: unloaded clamped=%llu whits=%llu\n", clamped, whits);
}

module_init(dpclamp_init);
module_exit(dpclamp_exit);

/* --- modpost-equivalent --- */
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
