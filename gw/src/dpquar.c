// SPDX-License-Identifier: GPL-2.0
// dpquar.ko -- quarantine dpmaif-released pages so the MD's stale buffer list
// can never write into a page that was recycled to a user process.
//
// Mechanism (docs/SIGSEGV_ANALYSIS.md §1/§3): the cellular MD firmware keeps
// DMA-writing 16/32B ring records into RX buffer page PAs it learned from the
// AP driver; that list lives MD-side (invisible/unfixable from AP).  The only
// AP-side lever is to never let those pages flow back into the buddy pool:
// while a page holds one of our references it can be written by MD, but it can
// never become a user page -- the write is harmless.
//
// Implementation: patch the six `bl dma_unmap_page_attrs` call sites in the
// dpmaif driver (direct-bl redirect into module shims; machinery proven by
// dphook on 2026-10-22).  Each shim optionally takes a reference on the page
// behind dma_addr (== PA, no IOMMU on this SoC) before the original unmap,
// parks it in a bounded FIFO quarantine, and calls the original function.
// A 1Hz pass evicts expired entries (put_page) and diffs the page tail of
// every quarantined page -- a tail change is a "writer-hit", the direct
// acceptance readout that the mechanism is real and the fix is effective.
//
// Site classification (from ktext disassembly + live counters):
//   0  dpmaif_relase_tx_buffer+0x184   TX completion loop      hot  (count-only)
//   1  dpmaif_relase_tx_buffer+0x798   TX bulk/flush loop      warm (count-only)
//   2  dpmaif_rx_med_data_collect+0xa48  RX recycle (record)  cold in practice (1 call/40min) -> quarantine
//   3  dpmaif_rx_med_data_collect+0xfb8  RX recycle (shadow
//                                      array {page,dma,?,len})  cold -> quarantine
//   4  dpmaif_stop_rx_sw+0x25c        teardown bulk free      cold (quarantine)
//   5  dpmaif_stop_rx_sw+0x2a8        teardown bulk free      cold (quarantine)
// Default qmask=0x30 (sites 4,5).  Hot sites stay count-only so a per-packet
// path can never flood the quarantine; raise the mask only after reading the
// counters (e.g. if writer-hits stay 0 while injections continue).
//
// usage: insmod dpquar.ko [qmask=0x3c] [hold_s=86400] [cap=16384] [watch=1]
//        cat /proc/dpquar
//        echo reset > /proc/dpquar        (clear event log only)
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/moduleparam.h>
#include <linux/mm.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/timer.h>
#include <linux/jiffies.h>
#include <linux/delay.h>
#include <linux/spinlock.h>
#include <linux/slab.h>
#include <linux/proc_fs.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dpquar: quarantine dpmaif-released pages against MD stale-list writes");

/* ---------- tunables ---------- */
static int qmask = 0x3c;		/* default: quarantine rx-recycle + teardown sites (2,3,4,5) */
static int hold_s = 86400;		/* quarantine TTL */
static int cap = 16384;			/* max quarantined pages (64MB = full RX pool observed 2026-10-22) */
static int watch = 1;			/* tail-watch quarantined pages */
static unsigned long p_patchfn = 0xffffffc008122394UL;	/* aarch64_insn_patch_text */
static unsigned long p_unmap = 0xffffffc00819b1b4UL;	/* dma_unmap_page_attrs */

module_param_named(qmask, qmask, int, 0444);
module_param_named(hold_s, hold_s, int, 0444);
module_param_named(cap, cap, int, 0444);
module_param_named(watch, watch, int, 0444);
module_param_named(patchfn, p_patchfn, ulong, 0444);

#define PA_BASE		0x80000000UL
#define PA_LIM		0xffc00000UL
#define LINBASE		0xffffff8000000000UL
#define LINMAP(pa)	(LINBASE + ((unsigned long)(pa) - PA_BASE))

/* ---------- patch sites (verified against ktext.bin 2026-10-22) ---------- */
#define S_TX1	0xffffffc00855e704UL	/* dpmaif_relase_tx_buffer+0x184 */
#define S_TX2	0xffffffc00855ed18UL	/* dpmaif_relase_tx_buffer+0x798 */
#define S_RX1	0xffffffc0085606b8UL	/* dpmaif_rx_med_data_collect+0xa48 */
#define S_RX2	0xffffffc008560c28UL	/* dpmaif_rx_med_data_collect+0xfb8 */
#define S_ST1	0xffffffc008562fa8UL	/* dpmaif_stop_rx_sw+0x25c */
#define S_ST2	0xffffffc008562ff4UL	/* dpmaif_stop_rx_sw+0x2a8 */

static const unsigned long sites[6] = { S_TX1, S_TX2, S_RX1, S_RX2, S_ST1, S_ST2 };
static const u32 orig_words[6] = {
	0x97f0f2acu, 0x97f0f127u, 0x97f0eabfu, 0x97f0e963u, 0x97f0e083u, 0x97f0e070u,
};

/* ---------- quarantine table ---------- */
struct qent {
	struct page *page;
	unsigned long pa;
	unsigned long j;
	u64 tail;		/* xor-fold of last 64B, for writer-hit detect */
};

static struct qent *qtab;
static int qcount;			/* valid entries [0..cap) */
static DEFINE_SPINLOCK(q_lock);

static u64 cnt_call[6], cnt_quar[6], cnt_dupe, cnt_rzero;
static u64 cnt_evict_ttl, cnt_evict_full, cnt_whits;
static u64 wh_ev[16][2];		/* {pa, j} of last writer-hits */
static int wh_n;

/* ---------- helpers ---------- */
static u64 tail_digest(struct page *pg)
{
	u64 t[8];

	if (copy_from_kernel_nofault(t, page_address(pg) + (PAGE_SIZE - 64), 64))
		return 0;
	return t[0] ^ t[1] ^ t[2] ^ t[3] ^ t[4] ^ t[5] ^ t[6] ^ t[7];
}

static void quarantine(int si, unsigned long addr)
{
	unsigned long pa = addr & ~0xfffUL;
	struct page *pg;
	int i;

	cnt_call[si]++;
	if (!(qmask & (1 << si)))
		return;
	if (pa < PA_BASE || pa >= PA_LIM)
		return;
	if (!pfn_valid(pa >> PAGE_SHIFT))
		return;
	pg = compound_head(pfn_to_page(pa >> PAGE_SHIFT));
	if (!get_page_unless_zero(pg)) {
		/* refcount 0: page already back in buddy -- too late for it,
		 * but this is exactly the "freed while still listed" shape. */
		cnt_rzero++;
		return;
	}
	spin_lock(&q_lock);
	for (i = 0; i < qcount; i++)
		if (qtab[i].pa == pa) {	/* already held */
			put_page(pg);
			spin_unlock(&q_lock);
			cnt_dupe++;
			return;
		}
	if (qcount >= cap) {		/* FIFO evict oldest */
		struct qent old = qtab[0];

		memmove(&qtab[0], &qtab[1], (size_t)(cap - 1) * sizeof(*qtab));
		qcount--;
		cnt_evict_full++;
		if (old.page)
			put_page(old.page);
	}
	qtab[qcount].page = pg;
	qtab[qcount].pa = pa;
	qtab[qcount].j = jiffies;
	qtab[qcount].tail = watch ? tail_digest(pg) : 0;
	qcount++;
	cnt_quar[si]++;
	spin_unlock(&q_lock);
}

/* ---------- shims (naked entry per site -> tail-jump into C body) ----------
 * dma_unmap_page_attrs(dev, addr, size, dir, attrs): x0..x4, returns void.
 * Pure tail jump keeps every register intact; the body returns to site+4. */
static noinline void dq_body(int si, unsigned long dev, unsigned long addr,
			     unsigned long size, unsigned long dir,
			     unsigned long attrs)
{
	quarantine(si, addr);
	((void (*)(unsigned long, unsigned long, unsigned long, unsigned long,
		  unsigned long))p_unmap)(dev, addr, size, dir, attrs);
}

/* dq_body##n must have external linkage: the naked asm references the
 * symbol name and an asm-level ref to a `static` fn becomes UNDEF (dphook lesson). */
#define SHIM(n)								\
static __attribute__((naked)) void dq_entry##n(void)			\
{									\
	__asm__ volatile("b  dq_body" #n ::: "memory");			\
}									\
noinline void dq_body##n(unsigned long a, unsigned long b,	\
				unsigned long c, unsigned long d,	\
				unsigned long e)			\
{									\
	dq_body(n, a, b, c, d, e);					\
}

SHIM(0) SHIM(1) SHIM(2) SHIM(3) SHIM(4) SHIM(5)

static void * const entries[6] = {
	dq_entry0, dq_entry1, dq_entry2, dq_entry3, dq_entry4, dq_entry5,
};

/* ---------- patching ---------- */
typedef int (*patch_fn_t)(void **, u32 *, int);

static int patched;

static u32 bl_to(unsigned long site, unsigned long target)
{
	long d = ((long)target - (long)site) >> 2;

	return 0x94000000u | ((u32)d & 0x3ffffffu);
}

static int apply_patch(unsigned long site, u32 word)
{
	void *addrs[1];
	u32 insns[1];
	u32 back;
	int ok;

	addrs[0] = (void *)site;
	insns[0] = word;
	if (((patch_fn_t)p_patchfn)(addrs, insns, 1))
		return -1;
	back = 0;
	copy_from_kernel_nofault(&back, (void *)site, 4);
	return back == word ? 0 : -1;
}

static int patches_install(void)
{
	int i, ok;

	for (i = 0; i < 6; i++) {
		u32 w = 0;

		if (copy_from_kernel_nofault(&w, (void *)sites[i], 4) ||
		    w != orig_words[i]) {
			pr_err("dpquar: REFUSE site %d %#lx = %#x want %#x\n",
			       i, sites[i], w, orig_words[i]);
			goto unwind;
		}
	}
	for (i = 0; i < 6; i++)
		if (apply_patch(sites[i], bl_to(sites[i],
						(unsigned long)entries[i]))) {
			pr_err("dpquar: patch site %d failed\n", i);
			goto unwind;
		}
	patched = 1;
	pr_info("dpquar: 6 shims installed qmask=%#x hold_s=%d cap=%d watch=%d\n",
		qmask, hold_s, cap, watch);
	return 0;
unwind:
	while (--i >= 0)
		apply_patch(sites[i], orig_words[i]);
	return -EIO;
}

static void patches_remove(void)
{
	int i;

	if (!patched)
		return;
	for (i = 5; i >= 0; i--)
		if (apply_patch(sites[i], orig_words[i]))
			pr_err("dpquar: RESTORE FAILED site %d %#lx\n", i, sites[i]);
	patched = 0;
	msleep(1000);		/* let any in-flight shim finish */
}

/* ---------- 1Hz maintenance: TTL evict + writer-hit watch ---------- */
static struct timer_list dq_timer;

static void dq_tick(struct timer_list *t)
{
	int i;

	spin_lock(&q_lock);
	for (i = 0; i < qcount; ) {
		if (time_after(jiffies, qtab[i].j + (unsigned long)hold_s * HZ)) {
			if (watch) {
				u64 d = tail_digest(qtab[i].page);

				if (d && d != qtab[i].tail && wh_n < 16) {
					wh_ev[wh_n][0] = qtab[i].pa;
					wh_ev[wh_n][1] = jiffies;
					wh_n++;
					cnt_whits++;
				}
			}
			put_page(qtab[i].page);
			memmove(&qtab[i], &qtab[i + 1],
				(size_t)(qcount - i - 1) * sizeof(*qtab));
			qcount--;
			cnt_evict_ttl++;
			continue;
		}
		i++;
	}
	if (watch) {
		for (i = 0; i < qcount; i++) {
			u64 d = tail_digest(qtab[i].page);

			if (d && d != qtab[i].tail) {
				qtab[i].tail = d;
				if (wh_n < 16) {
					wh_ev[wh_n][0] = qtab[i].pa;
					wh_ev[wh_n][1] = jiffies;
					wh_n++;
				}
				cnt_whits++;
			}
		}
	}
	spin_unlock(&q_lock);
	mod_timer(&dq_timer, jiffies + HZ);
}

/* ---------- proc ---------- */
static char pbuf[4096];
static int pbuf_len, pbuf_ready;

static ssize_t dq_read(struct file *f, char __user *ub, size_t n, loff_t *off)
{
	int len = 0, chunk, r, i;

	if (pbuf_ready && *off >= pbuf_len)
		return 0;
	if (*off == 0) {
		unsigned long fl;

		spin_lock_irqsave(&q_lock, fl);
		len += scnprintf(pbuf + len, sizeof(pbuf) - len,
			"dpquar patched=%d qmask=%#x held=%d/%d whits=%llu\n"
			"call tx1=%llu tx2=%llu rx1=%llu rx2=%llu st1=%llu st2=%llu\n"
			"quar tx1=%llu tx2=%llu rx1=%llu rx2=%llu st1=%llu st2=%llu\n"
			"dupe=%llu rzero=%llu evict_ttl=%llu evict_full=%llu\n",
			patched, qmask, qcount, cap, cnt_whits,
			cnt_call[0], cnt_call[1], cnt_call[2],
			cnt_call[3], cnt_call[4], cnt_call[5],
			cnt_quar[0], cnt_quar[1], cnt_quar[2],
			cnt_quar[3], cnt_quar[4], cnt_quar[5],
			cnt_dupe, cnt_rzero, cnt_evict_ttl, cnt_evict_full);
		for (i = 0; i < wh_n; i++)
			len += scnprintf(pbuf + len, sizeof(pbuf) - len,
				"whit[%d] pa=%#llx j=%llu\n", i,
				wh_ev[i][0], wh_ev[i][1]);
		spin_unlock_irqrestore(&q_lock, fl);
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

static ssize_t dq_write(struct file *f, const char __user *ub, size_t n, loff_t *off)
{
	char buf[16];
	unsigned long fl;

	if (n > sizeof(buf) - 1)
		n = sizeof(buf) - 1;
	if (copy_from_user(buf, ub, n))
		return -EFAULT;
	buf[n] = 0;
	if (!strncmp(buf, "reset", 5)) {
		spin_lock_irqsave(&q_lock, fl);
		wh_n = 0;
		spin_unlock_irqrestore(&q_lock, fl);
		pbuf_ready = 0;
	}
	return n;
}

static loff_t dq_lseek(struct file *f, loff_t off, int whence) { return 0; }

static const struct proc_ops dq_ops = {
	.proc_read = dq_read,
	.proc_write = dq_write,
	.proc_lseek = dq_lseek,
};

/* ---------- init/exit ---------- */
static int __init dpquar_init(void)
{
	int rc;

	if (cap < 16 || cap > 65536)
		cap = 16384;
	qtab = kcalloc(cap, sizeof(*qtab), GFP_KERNEL);
	if (!qtab)
		return -ENOMEM;
	rc = patches_install();
	if (rc) {
		pr_err("dpquar: shim install failed (%d), aborting\n", rc);
		kfree(qtab);
		qtab = NULL;
		return rc;
	}
	timer_setup(&dq_timer, dq_tick, 0);
	mod_timer(&dq_timer, jiffies + HZ);
	proc_create("dpquar", 0666, NULL, &dq_ops);
	pr_info("dpquar: ready\n");
	return 0;
}

static void __exit dpquar_exit(void)
{
	int i;

	remove_proc_entry("dpquar", NULL);
	del_timer_sync(&dq_timer);
	patches_remove();
	if (qtab) {
		spin_lock(&q_lock);
		for (i = 0; i < qcount; i++)
			put_page(qtab[i].page);
		qcount = 0;
		spin_unlock(&q_lock);
		kfree(qtab);
		qtab = NULL;
	}
	pr_info("dpquar: unloaded quar_total=%llu whits=%llu\n",
		cnt_quar[0] + cnt_quar[1] + cnt_quar[2] + cnt_quar[3] +
		cnt_quar[4] + cnt_quar[5], cnt_whits);
}

module_init(dpquar_init);
module_exit(dpquar_exit);

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
