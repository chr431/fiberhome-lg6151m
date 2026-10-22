// SPDX-License-Identifier: GPL-2.0
// dpquar.ko -- quarantine dpmaif-released pages so the MD's stale buffer list
// can never write into a page that was recycled to a user process.
//
// Mechanism (docs/SIGSEGV_ANALYSIS.md section 1/3): the cellular MD firmware
// keeps DMA-writing 16/32B ring records into RX buffer page PAs it learned
// from the AP driver; that list lives MD-side (invisible/unfixable from AP).
// The only AP-side lever is to never let those pages flow back into the buddy
// pool: while a page holds one of our references it can still be written by
// MD, but it can never become a user page -- the write is harmless.
//
// Implementation: patch the ten call sites in the dpmaif driver where buffers
// are unmapped or pages returned (direct-bl redirect into module shims;
// machinery proven by dphook 2026-10-22).  A shim optionally takes a
// reference on the page behind the address before the original call, parks it
// in a bounded FIFO quarantine, then calls the original function.
//
// v1.3 CRITICAL FIX (2026-10-22 20:45 postmortem): v1.1/v1.2 did the
// duplicate-page check as a linear scan of the whole table under the table
// spinlock.  A full teardown (~32768 calls, ~15923 pages) turns that into a
// quadratic burst of non-preemptible work -> RCU stall -> panic_on_rcu_stall
// -> device reboot (aee db.fatal.04.KE: quarantine_page+0x328 <-
// dpmaif_stop+0xf8).  Dedup is now an open-addressing hash (O(1) per call,
// lock hold bounded), TTL eviction batches put_page outside the lock.
//
// Sites (words verified against ktext.bin 2026-10-22; mismatch refuses):
//  unmap family: dma_unmap_page_attrs(dev, addr, size, dir, attrs), addr=PA
//   0 dpmaif_relase_tx_buffer+0x184      TX completion    hot  count-only
//   1 dpmaif_relase_tx_buffer+0x798      TX bulk loop     warm count-only
//   2 dpmaif_rx_med_data_collect+0xa48   RX recycle       cold -> quarantine
//   3 dpmaif_rx_med_data_collect+0xfb8   RX recycle/shdw  cold -> quarantine
//   4 dpmaif_stop_rx_sw+0x25c            teardown unmap   cold -> quarantine
//   5 dpmaif_stop_rx_sw+0x2a8            teardown unmap   cold -> quarantine
//  return family: the only four direct page-return sites in the driver
//   6 dpmaif_stop_rx_sw+0x1a4   __page_frag_cache_drain(page,count)
//   7 dpmaif_stop_rx_sw+0x2b0   put_page(page)
//   8 dpmaif_alloc_med_rx_buf+0x1bc   page_frag_free(vaddr)
//   9 dpmaif_alloc_med_rx_frag+0x1b0   put_page(page)   (error path)
//
// usage: insmod dpquar.ko [qmask=0x3fc] [hold_s=86400] [cap=16384] [watch=1]
//        cat /proc/dpquar ; echo reset > /proc/dpquar
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
static int qmask = 0x3fc;	/* quarantine sites 2..9; TX sites count-only */
static int hold_s = 86400;	/* quarantine TTL */
static int cap = 16384;		/* max quarantined pages (64MB = one full pool) */
static int watch = 1;		/* tail-watch quarantined pages for writer hits */
static unsigned long p_patchfn = 0xffffffc008122394UL;	/* aarch64_insn_patch_text */

module_param_named(qmask, qmask, int, 0444);
module_param_named(hold_s, hold_s, int, 0444);
module_param_named(cap, cap, int, 0444);
module_param_named(watch, watch, int, 0444);
module_param_named(patchfn, p_patchfn, ulong, 0444);

#define PA_BASE		0x80000000UL
#define PA_LIM		0xffc00000UL
#define LINBASE		0xffffff8000000000UL
#define PAOF(va)	((unsigned long)(va) - LINBASE + PA_BASE)

/* ---------- patch sites ---------- */
#define S_TX1	0xffffffc00855e704UL	/* dpmaif_relase_tx_buffer+0x184 */
#define S_TX2	0xffffffc00855ed18UL	/* dpmaif_relase_tx_buffer+0x798 */
#define S_RX1	0xffffffc0085606b8UL	/* dpmaif_rx_med_data_collect+0xa48 */
#define S_RX2	0xffffffc008560c28UL	/* dpmaif_rx_med_data_collect+0xfb8 */
#define S_ST1	0xffffffc008562fa8UL	/* dpmaif_stop_rx_sw+0x25c */
#define S_ST2	0xffffffc008562ff4UL	/* dpmaif_stop_rx_sw+0x2a8 */
#define R_DRAIN	0xffffffc008562ef0UL	/* dpmaif_stop_rx_sw+0x1a4  __page_frag_cache_drain */
#define R_PUT	0xffffffc008562ffcUL	/* dpmaif_stop_rx_sw+0x2b0  put_page */
#define R_AFB	0xffffffc00855e28cUL	/* dpmaif_alloc_med_rx_buf+0x1bc  page_frag_free */
#define R_AFF	0xffffffc00855fc38UL	/* dpmaif_alloc_med_rx_frag+0x1b0  put_page */

#define NSITES	10
static const unsigned long sites[NSITES] = {
	S_TX1, S_TX2, S_RX1, S_RX2, S_ST1, S_ST2, R_DRAIN, R_PUT, R_AFB, R_AFF,
};
static const u32 orig_words[NSITES] = {
	0x97f0f2acu, 0x97f0f127u, 0x97f0eabfu, 0x97f0e963u, 0x97f0e083u, 0x97f0e070u,
	0x97f3f2fdu, 0x97ffeab6u, 0x97f40626u, 0x97fff7a7u,
};

/* ---------- quarantine table (FIFO + hash dedup) ----------
 * qtab is the FIFO ring of held pages; hslots[] is an open-addressing index
 * pa -> qtab position (0 = empty, position stored +1).  Every operation is
 * O(1); the spinlock is never held across more than a few words of work. */
struct qent {
	struct page *page;
	unsigned long pa;
	unsigned long j;
	u64 tail;
};

static struct qent *qtab;
static int *hslots;
static int hmask;
static int qhead, qtail_;		/* FIFO ring: entries [qhead, qtail_) */
static DEFINE_SPINLOCK(q_lock);

static u64 cnt_call[NSITES], cnt_quar[NSITES];
static u64 cnt_dupe, cnt_rzero, cnt_evict_ttl, cnt_evict_full, cnt_whits;
static u64 wh_ev[16][2];
static int wh_n;

static int h_lookup(unsigned long pa, int *slot)
{
	int i = (int)((pa >> 12) & (unsigned long)hmask);

	while (hslots[i]) {
		int p = hslots[i] - 1;

		if (p >= qhead && p < qtail_ && qtab[p].pa == pa) {
			*slot = i;
			return 1;
		}
		i = (i + 1) & hmask;
	}
	*slot = i;
	return 0;
}

static void h_erase_pos(int p)
{
	int i = (int)((qtab[p].pa >> 12) & (unsigned long)hmask);

	while (hslots[i] && hslots[i] - 1 != p)
		i = (i + 1) & hmask;
	if (!hslots[i])
		return;
	hslots[i] = 0;
	{
		int j = (i + 1) & hmask;

		while (hslots[j]) {
			int q = hslots[j] - 1;
			int k = (int)((qtab[q].pa >> 12) & (unsigned long)hmask);
			int x = i;

			while (x != j && x != k)
				x = (x + 1) & hmask;
			if (x == i) {
				hslots[i] = hslots[j];
				hslots[j] = 0;
				i = j;
			}
			j = (j + 1) & hmask;
		}
	}
}

static u64 tail_digest(struct page *pg)
{
	u64 t[8];

	if (copy_from_kernel_nofault(t, page_address(pg) + (PAGE_SIZE - 64), 64))
		return 0;
	return t[0] ^ t[1] ^ t[2] ^ t[3] ^ t[4] ^ t[5] ^ t[6] ^ t[7];
}

/* core: must stay O(1) and brief -- a full teardown fires it ~32k times
 * back to back from inside dpmaif_stop (see v1.3 header note). */
static void quarantine_pa(int si, unsigned long pa)
{
	struct page *pg;
	int slot, pos;

	cnt_call[si]++;
	if (!(qmask & (1 << si)))
		return;
	if (pa < PA_BASE || pa >= PA_LIM || !pfn_valid(pa >> PAGE_SHIFT))
		return;
	pg = compound_head(pfn_to_page(pa >> PAGE_SHIFT));
	if (!get_page_unless_zero(pg)) {
		cnt_rzero++;		/* freed-before-unmap shape */
		return;
	}
	spin_lock(&q_lock);
	if (h_lookup(pa, &slot)) {
		put_page(pg);
		cnt_dupe++;
		spin_unlock(&q_lock);
		return;
	}
	if (qtail_ - qhead >= cap) {	/* FIFO full: evict oldest */
		struct qent *old = &qtab[qhead % cap];

		if (old->page)
			put_page(old->page);
		h_erase_pos(qhead % cap);
		qhead++;
		cnt_evict_full++;
		h_lookup(pa, &slot);	/* probe hole may have moved */
	}
	pos = qtail_ % cap;
	qtab[pos].page = pg;
	qtab[pos].pa = pa;
	qtab[pos].j = jiffies;
	qtab[pos].tail = watch ? tail_digest(pg) : 0;
	hslots[slot] = pos + 1;
	qtail_++;
	cnt_quar[si]++;
	spin_unlock(&q_lock);
}

static void quarantine_page(int si, struct page *p)
{
	if ((unsigned long)p < 0xfffffffe00000000UL ||
	    (unsigned long)p >= 0xfffffffe02000000UL)
		return;
	quarantine_pa(si,
		      (unsigned long)page_to_pfn(compound_head(p)) << PAGE_SHIFT);
}

static void quarantine_vaddr(int si, unsigned long va)
{
	if (va < LINBASE || va >= 0xffffffc000000000UL)
		return;
	quarantine_pa(si, PAOF(va) & ~0xfffUL);
}

/* ---------- shims ----------
 * Unmap family (x0..x4, void return): naked entry tail-jumps into a C body
 * which returns straight to the original caller.  Return family: one shim
 * per callee signature.  C bodies are extern: the naked asm references the
 * symbol name and a static symbol would become UNDEF in the .ko. */
static noinline void dq_body(int si, unsigned long dev, unsigned long addr,
			     unsigned long size, unsigned long dir,
			     unsigned long attrs)
{
	quarantine_pa(si, addr & ~0xfffUL);
	((void (*)(unsigned long, unsigned long, unsigned long, unsigned long,
		  unsigned long))0xffffffc00819b1b4UL)(dev, addr, size, dir, attrs);
}

#define SHIM(n)								\
static __attribute__((naked)) void dq_entry##n(void)			\
{									\
	__asm__ volatile("b  dq_body" #n ::: "memory");			\
}									\
noinline void dq_body##n(unsigned long a, unsigned long b,		\
			 unsigned long c, unsigned long d,		\
			 unsigned long e)				\
{									\
	dq_body(n, a, b, c, d, e);					\
}

SHIM(0) SHIM(1) SHIM(2) SHIM(3) SHIM(4) SHIM(5)

static __attribute__((naked)) void dq_entry6(void)
{
	__asm__ volatile("b  dqr_drain" ::: "memory");
}
noinline void dqr_drain(unsigned long page, unsigned long count)
{
	quarantine_page(6, (struct page *)page);
	((void (*)(unsigned long, unsigned long))0xffffffc00825fae4UL)(page, count);
}

static __attribute__((naked)) void dq_entry7(void)
{
	__asm__ volatile("b  dqr_put" ::: "memory");
}
noinline void dqr_put(unsigned long page)
{
	quarantine_page(7, (struct page *)page);
	((void (*)(unsigned long))0xffffffc00855dad4UL)(page);	/* put_page */
}

static __attribute__((naked)) void dq_entry8(void)
{
	__asm__ volatile("b  dqr_afb" ::: "memory");
}
noinline void dqr_afb(unsigned long va)
{
	quarantine_vaddr(8, va);
	((void (*)(unsigned long))0xffffffc00825fb24UL)(va);	/* page_frag_free */
}

static __attribute__((naked)) void dq_entry9(void)
{
	__asm__ volatile("b  dqr_aff" ::: "memory");
}
noinline void dqr_aff(unsigned long page)
{
	quarantine_page(9, (struct page *)page);
	((void (*)(unsigned long))0xffffffc00855dad4UL)(page);	/* put_page */
}

static void * const entries[NSITES] = {
	dq_entry0, dq_entry1, dq_entry2, dq_entry3, dq_entry4, dq_entry5,
	dq_entry6, dq_entry7, dq_entry8, dq_entry9,
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
	u32 back = 0;

	addrs[0] = (void *)site;
	insns[0] = word;
	if (((patch_fn_t)p_patchfn)(addrs, insns, 1))
		return -1;
	copy_from_kernel_nofault(&back, (void *)site, 4);
	return back == word ? 0 : -1;
}

static int patches_install(void)
{
	int i;

	for (i = 0; i < NSITES; i++) {
		u32 w = 0;

		if (copy_from_kernel_nofault(&w, (void *)sites[i], 4) ||
		    w != orig_words[i]) {
			pr_err("dpquar: REFUSE site %d %#lx = %#x want %#x\n",
			       i, sites[i], w, orig_words[i]);
			goto unwind;
		}
	}
	for (i = 0; i < NSITES; i++)
		if (apply_patch(sites[i], bl_to(sites[i],
						(unsigned long)entries[i]))) {
			pr_err("dpquar: patch site %d failed\n", i);
			goto unwind;
		}
	patched = 1;
	pr_info("dpquar: %d shims installed qmask=%#x hold_s=%d cap=%d watch=%d\n",
		NSITES, qmask, hold_s, cap, watch);
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
	for (i = NSITES - 1; i >= 0; i--)
		if (apply_patch(sites[i], orig_words[i]))
			pr_err("dpquar: RESTORE FAILED site %d %#lx\n", i, sites[i]);
	patched = 0;
	msleep(1000);		/* let any in-flight shim finish */
}

/* ---------- 1Hz maintenance: TTL evict + writer-hit watch ---------- */
static struct timer_list dq_timer;

static void dq_tick(struct timer_list *t)
{
	struct page *rel[64];
	int nrel = 0, i;

	spin_lock(&q_lock);
	while (qhead < qtail_ && nrel < 64) {
		struct qent *e = &qtab[qhead % cap];

		if (!time_after(jiffies, e->j + (unsigned long)hold_s * HZ))
			break;
		if (e->page)
			rel[nrel++] = e->page;
		h_erase_pos(qhead % cap);
		qhead++;
		cnt_evict_ttl++;
	}
	for (i = qhead; i < qtail_; i++) {
		struct qent *e = &qtab[i % cap];
		u64 d;

		if (!e->tail)
			continue;	/* watch off or page unreadable */
		d = tail_digest(e->page);
		if (d && d != e->tail) {
			e->tail = d;
			if (wh_n < 16) {
				wh_ev[wh_n][0] = e->pa;
				wh_ev[wh_n][1] = jiffies;
				wh_n++;
			}
			cnt_whits++;
		}
	}
	spin_unlock(&q_lock);
	for (i = 0; i < nrel; i++)
		put_page(rel[i]);
	mod_timer(&dq_timer, jiffies + HZ);
}

/* ---------- proc ---------- */
static char pbuf[4096];
static int pbuf_len, pbuf_ready;

static ssize_t dq_read(struct file *f, char __user *ub, size_t n, loff_t *off)
{
	int len = 0, chunk, r, i;
	unsigned long fl;

	if (pbuf_ready && *off >= pbuf_len)
		return 0;
	if (*off == 0) {
		spin_lock_irqsave(&q_lock, fl);
		len += scnprintf(pbuf + len, sizeof(pbuf) - len,
			"dpquar patched=%d qmask=%#x held=%d/%d whits=%llu\n",
			patched, qmask, qtail_ - qhead, cap, cnt_whits);
		len += scnprintf(pbuf + len, sizeof(pbuf) - len,
			"call tx1=%llu tx2=%llu rx1=%llu rx2=%llu st1=%llu st2=%llu drain=%llu put=%llu afb=%llu aff=%llu\n",
			cnt_call[0], cnt_call[1], cnt_call[2], cnt_call[3],
			cnt_call[4], cnt_call[5], cnt_call[6], cnt_call[7],
			cnt_call[8], cnt_call[9]);
		len += scnprintf(pbuf + len, sizeof(pbuf) - len,
			"quar tx1=%llu tx2=%llu rx1=%llu rx2=%llu st1=%llu st2=%llu drain=%llu put=%llu afb=%llu aff=%llu\n",
			cnt_quar[0], cnt_quar[1], cnt_quar[2], cnt_quar[3],
			cnt_quar[4], cnt_quar[5], cnt_quar[6], cnt_quar[7],
			cnt_quar[8], cnt_quar[9]);
		len += scnprintf(pbuf + len, sizeof(pbuf) - len,
			"dupe=%llu rzero=%llu evict_ttl=%llu evict_full=%llu\n",
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
	hmask = 1;
	while (hmask < cap * 2)
		hmask <<= 1;
	hmask--;
	hslots = kcalloc(hmask + 1, sizeof(*hslots), GFP_KERNEL);
	if (!qtab || !hslots) {
		kfree(qtab);
		kfree(hslots);
		return -ENOMEM;
	}
	rc = patches_install();
	if (rc) {
		pr_err("dpquar: shim install failed (%d), aborting\n", rc);
		kfree(qtab);
		kfree(hslots);
		qtab = NULL;
		hslots = NULL;
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
		for (i = qhead; i < qtail_; i++)
			if (qtab[i % cap].page)
				put_page(qtab[i % cap].page);
		qhead = qtail_ = 0;
		spin_unlock(&q_lock);
		kfree(qtab);
		kfree(hslots);
		qtab = NULL;
		hslots = NULL;
	}
	pr_info("dpquar: unloaded\n");
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
