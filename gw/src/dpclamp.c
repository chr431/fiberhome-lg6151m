// SPDX-License-Identifier: GPL-2.0
// dpclamp.ko v1.3 -- episode-reactive stale-page clamp + deep free-list drain.
//
// Complement to dpquar (which stops NEW pages entering the MD stale list at
// dpmaif teardown).  The MD-side accumulated stale list keeps being rewritten
// (~1 page/s during episodes); v1.2 suppressed it with fixed-period order-0
// sampling, but 48h of NE ledger (2026-10-24/25) showed the residual rate is
// set by two structural gaps: sampling only sees one CPU's pcp + the order-0
// freelist (95% of free memory hides inside order>=9 blocks), and nothing
// accelerates when an episode starts (idle ladder cools to 60s patrol).
// Analysis and design: docs/SIGSEGV_ANALYSIS.md section 8.9/8.10.
//
// v1.3 adds:
//   * deep drain -- two-phase traversal of ALL buddy free lists (every order,
//     every migratetype): phase 1 collects block heads under per-list
//     zone->lock (<=~100us per take), phase 2 reads every subpage tail lock-
//     free, phase 3 re-verifies candidates under zone->lock and removes the
//     whole block, freeing unsigned siblings and holding the signed pages.
//   * three triggers -- whits delta (writer just hit a held page), NE probe
//     (core_meta writes "deep" to /proc/dpclamp on every crash, 300s
//     cooldown), boot warm-up (deep + one burst at module load).
//   * burst mode -- back-to-back sweeps for <=90s (extend on clamps, hard
//     cap 10min, early stop after 3 empty sweeps) to churn the pcp hot pool.
//   * SMP rotation -- the kthread rotates its CPU affinity per sweep/deep so
//     each CPU's pcp gets sampled.
//   * fixes: digest init double-XOR (D1), watch cursor starvation (D2),
//     signature window widened to 4 slots + RAM-PA-shaped values (D3),
//     /proc v2 telemetry with a 16-entry trigger ring (D4), held pages now
//     keep exactly one reference (v1.2 leaked one ref per held page until
//     reboot -- harmless under the daily 04:00 reboot, wrong anyway).
//
// usage: insmod dpclamp.ko [period_s=120] [batch=1024] [cap=8192]
//                    [minfree_kb=150000] [warmup=1] [cool_s=300]
//        cat /proc/dpclamp          ; echo deep > /proc/dpclamp  (NE probe)
//        echo force > /proc/dpclamp ; echo burst > /proc/dpclamp (manual)
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/moduleparam.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/jiffies.h>
#include <linux/slab.h>
#include <linux/proc_fs.h>
#include <linux/spinlock.h>
#include <linux/kthread.h>
#include <linux/sched.h>
#include <linux/cpumask.h>
#include <linux/wait.h>
#include <linux/ktime.h>
#include <linux/vmstat.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dpclamp: clamp MD-stale-listed pages out of circulation");

static int period_s = 120;
static int batch = 1024;
static int cap = 8192;			/* 32MB max held */
static int minfree_kb = 150000;		/* stop draining below this MemFree (kB) */
static int warmup = 1;			/* deep+burst right after load (T-c) */
static int cool_s = 300;		/* NE-probe cooldown window */

module_param_named(period_s, period_s, int, 0444);
module_param_named(batch, batch, int, 0444);
module_param_named(cap, cap, int, 0444);
module_param_named(minfree_kb, minfree_kb, int, 0444);
module_param_named(warmup, warmup, int, 0444);
module_param_named(cool_s, cool_s, int, 0444);

#define PA_BASE		0x80000000UL
#define PA_END		0xef000000UL	/* RAM top per iomem (main seg ends 0xeeefffff) */
#define MAXORDER	11
#define MAXHEADS	2048
#define MAXCAND		256
#define RINGN		16

/* trigger sources */
enum { SRC_WHIT = 0, SRC_NEPROBE, SRC_BOOT, SRC_MANUAL, SRC_ESCA, SRC_N };
static const char *src_name[SRC_N] =
	{ "whit", "neprobe", "boot", "manual", "esca" };

struct cent {
	struct page *page;
	unsigned long pa;
	u64 tail;
	unsigned long j;
};
static struct cent *ctab;
static int ccount;
static DEFINE_SPINLOCK(c_lock);

/* deep-phase scratch (kthread context only) */
struct head_ent {
	struct page *page;
	struct zone *zone;
	unsigned char order;
	unsigned char mt;
};
static struct head_ent heads[MAXHEADS];
static struct head_ent cand[MAXCAND];

/* counters */
static u64 sweeps, alloced, clamped, freed_ok, whits;
static u64 sweep_us_last;
static int idle_sweeps, watch_pos;
static u64 deeps, d_heads, d_walked, d_cands, d_kept, d_grabbed;
static u64 d_ms_last, d_ms_max, d_lockus_last, d_lockus_max;
static u64 bursts, b_sweeps, b_clamped, b_ms_last, b_ms_max;
static u64 episodes, suppressed;
static int last_src = -1;
static u64 last_trig_ns;
static char ring_q[RINGN][96];
static int ring_i, ring_n;

/* trigger/burst state (t_lock) */
static DEFINE_SPINLOCK(t_lock);
static int pend_deep, pend_src;
static int burst_run, b_empty;
static unsigned long burst_deadline, burst_hard;

static struct task_struct *dct;
static DECLARE_WAIT_QUEUE_HEAD(dc_wait);

static void ring_push(const char *what, int src, u64 v1, u64 v2)
{
	scnprintf(ring_q[ring_i], sizeof(ring_q[0]), "%llu %s %s v1=%llu v2=%llu",
		  ktime_get_ns(), what, src_name[src], v1, v2);
	ring_i = (ring_i + 1) % RINGN;
	if (ring_n < RINGN)
		ring_n++;
}

/* ---------- signature (section 2.1 / 8.6 shape rules) ---------- */

static int small_or_pa(u64 v)
{
	return (v && v < 0x40000UL) || (v >= PA_BASE && v < PA_END);
}

/* v1.3: any of the four 16B slots of the last 64B may carry the record
 * (v1.2 only saw slots 0/1); PA-shaped record values accepted (buddyscan
 * parity); "other" nonzero words in the window still <= 1. */
static int tail_signed(const u64 *t)
{
	int s, k, other;

	for (s = 0; s < 4; s++) {
		if (!t[s] || t[s + 1] || !small_or_pa(t[s]))
			continue;
		other = 0;
		for (k = 0; k < 8; k++) {
			if (k == s || k == s + 1)
				continue;
			if (t[k])
				other++;
		}
		if (other <= 1)
			return 1;
	}
	return 0;
}

static u64 tail_digest(struct page *pg)
{
	u64 t[8];

	if (copy_from_kernel_nofault(t, page_address(pg) + (PAGE_SIZE - 64), 64))
		return 0;
	return t[0] ^ t[1] ^ t[2] ^ t[3] ^ t[4] ^ t[5] ^ t[6] ^ t[7];
}

/* append a page we already own (refcount 1) to the hold table */
static int hold_owned(struct page *pg, const u64 *t)
{
	unsigned long pa = (unsigned long)page_to_pfn(pg) << PAGE_SHIFT;
	int i;

	spin_lock(&c_lock);
	for (i = 0; i < ccount; i++)
		if (ctab[i].pa == pa) {
			spin_unlock(&c_lock);
			return 0;	/* already held */
		}
	if (ccount >= cap) {
		spin_unlock(&c_lock);
		return 0;
	}
	ctab[ccount].page = pg;
	ctab[ccount].pa = pa;
	/* v1.2 stored a digest that XORed t[3] twice (D1): first watch pass
	 * then always saw a "change".  Same function both ends now. */
	ctab[ccount].tail = t[0] ^ t[1] ^ t[2] ^ t[3] ^ t[4] ^ t[5] ^ t[6] ^ t[7];
	ctab[ccount].j = jiffies;
	ccount++;
	clamped++;
	spin_unlock(&c_lock);
	return 1;
}

/* ---------- sweep (pcp/order-0 hot pool) ---------- */

static int run_sweep(void)
{
	int i, nalloc = batch > 4096 ? 4096 : batch;
	int clamped_before = (int)clamped;
	int clamped_this;
	u64 t0 = ktime_get_ns();

	if (si_mem_available() < minfree_kb)
		return 0;
	for (i = 0; i < nalloc; i++) {
		/* HIGHUSER_MOVABLE: the signed pages are ex-anon and live in
		 * the MOVABLE migrate lists (GFP_KERNEL never samples those).
		 * __GFP_NORETRY: fail fast instead of compaction/reclaim
		 * storms (KE#3 class).  One page at a time -- the bulk array
		 * path oopsed in __free_pages (2026-10-22 KE). */
		struct page *pg = alloc_page(GFP_HIGHUSER_MOVABLE |
					     __GFP_NORETRY | __GFP_NOWARN);
		u64 t[8];

		if (!pg)
			break;
		alloced++;
		if (!copy_from_kernel_nofault(t, page_address(pg) + (PAGE_SIZE - 64), 64) &&
		    tail_signed(t) && hold_owned(pg, t)) {
			freed_ok++;	/* kept */
			continue;
		}
		__free_page(pg);
		if ((i & 0x3f) == 0x3f)
			cond_resched();
	}
	sweeps++;
	sweep_us_last = (ktime_get_ns() - t0) / 1000;
	clamped_this = (int)clamped - clamped_before;
	if (clamped_this > 0)
		idle_sweeps = 0;
	else if (idle_sweeps < 1000)
		idle_sweeps++;
	return clamped_this;
}

/* ---------- deep drain (all buddy lists, two-phase) ---------- */

static void start_burst(int src);

/* phase 3: walk the candidate's own list, re-verify, unhook the block.
 * Mirrors rmqueue()/__isolate_free_page() accounting under the same lock:
 * free-area nr_free, NR_FREE_PAGES (+CMA) vmstat, and page->index so the
 * later free path reads a valid pcp migratetype.  Deviation from
 * __isolate_free_page: the WMARK_MIN check is replaced by the coarser
 * minfree_kb gate (150MB >> watermark) and the pageblock-migratetype
 * fixup for >=half-pageblock steals is skipped (metadata heuristic). */
static int grab_cand(const struct head_ent *ce)
{
	struct zone *z = ce->zone;
	unsigned int o = ce->order, mt = ce->mt;
	struct list_head *p, *n;
	unsigned long fl;
	struct page *head = ce->page;
	int got = 0;

	spin_lock_irqsave(&z->lock, fl);
	list_for_each_safe(p, n, &z->free_area[o].free_list[mt]) {
		struct page *pg = list_entry(p, struct page, lru);

		if (pg != head)
			continue;
		/* still a free block head on this list: take the block */
		list_del(&pg->lru);
		set_page_private(pg, 0);
		__ClearPageBuddy(pg);
		z->free_area[o].nr_free--;
		__mod_zone_freepage_state(z, -(1 << o), mt);
		pg->index = mt;		/* set_pcppage_migratetype parity */
		got = 1;
		break;
	}
	spin_unlock_irqrestore(&z->lock, fl);
	return got;
}

static void process_block(struct page *head, unsigned int order)
{
	unsigned int npgs = 1u << order, k;

	set_page_count(head, 1);
	if (order > 0)
		split_page(head, order);	/* exported; refcounts siblings */
	for (k = 0; k < npgs; k++) {
		u64 t[8];

		if (copy_from_kernel_nofault(t, page_address(head + k) +
					     (PAGE_SIZE - 64), 64))
			goto free_it;
		if (tail_signed(t) && hold_owned(head + k, t))
			continue;		/* kept: refcount already ours */
free_it:
		__free_page(head + k);		/* unsigned sibling: back it goes */
		if ((k & 0x3f) == 0x3f)
			cond_resched();
	}
}

static void run_deep(int src)
{
	u64 t0 = ktime_get_ns(), tlock;
	u64 clamped0 = clamped;
	int nheads = 0, nsigned = 0, grabbed = 0;
	int zi, o, mt, i;
	struct zone *z;
	unsigned long fl;

	if (si_mem_available() < minfree_kb) {
		suppressed++;
		return;
	}
	/* phase 1: collect block heads, one list per lock take */
	for (zi = 0; zi < MAX_NR_ZONES; zi++) {
		z = &contig_page_data.node_zones[zi];
		if (!populated_zone(z))
			continue;
		for (o = 0; o < MAXORDER; o++) {
			for (mt = 0; mt < MIGRATE_TYPES; mt++) {
				struct list_head *p;

				tlock = ktime_get_ns();
				spin_lock_irqsave(&z->lock, fl);
				list_for_each(p, &z->free_area[o].free_list[mt]) {
					if (nheads >= MAXHEADS)
						break;
					heads[nheads].page =
						list_entry(p, struct page, lru);
					heads[nheads].zone = z;
					heads[nheads].order = o;
					heads[nheads].mt = mt;
					nheads++;
				}
				spin_unlock_irqrestore(&z->lock, fl);
				tlock = (ktime_get_ns() - tlock) / 1000;
				if (tlock > d_lockus_last)
					d_lockus_last = tlock;
				if (tlock > d_lockus_max)
					d_lockus_max = tlock;
			}
		}
	}
	/* phase 2: read every subpage tail, lock-free */
	for (i = 0; i < nheads; i++) {
		unsigned int npgs = 1u << heads[i].order;
		unsigned int k;
		int sig = 0;

		for (k = 0; k < npgs; k++) {
			u64 t[8];

			if (!copy_from_kernel_nofault(t, page_address(heads[i].page + k) +
						       (PAGE_SIZE - 64), 64)) {
				d_walked++;
				if (tail_signed(t))
					sig = 1;
			}
			if ((k & 0x3f) == 0x3f)
				cond_resched();
		}
		if (sig && nsigned < MAXCAND)
			cand[nsigned++] = heads[i];
		if ((i & 0x1f) == 0x1f)
			cond_resched();
	}
	/* phase 3: re-verify + unhook + keep signed / free siblings */
	for (i = 0; i < nsigned; i++) {
		if (grab_cand(&cand[i])) {
			process_block(cand[i].page, cand[i].order);
			grabbed++;
		}
		if ((i & 0x1f) == 0x1f)
			cond_resched();
	}

	d_heads += nheads;
	d_cands += nsigned;
	d_grabbed += grabbed;
	deeps++;
	d_ms_last = (ktime_get_ns() - t0) / 1000000;
	if (d_ms_last > d_ms_max)
		d_ms_max = d_ms_last;
	last_src = src;
	last_trig_ns = ktime_get_ns();
	ring_push("deep", src, d_ms_last, d_lockus_last);
	pr_info("dpclamp: deep src=%s heads=%d walked=%llu cands=%d kept=%llu ms=%llu lockus=%llu\n",
		src_name[src], nheads, d_walked, nsigned, clamped, d_ms_last,
		d_lockus_last);
	if (clamped - clamped0 >= 8)	/* real episode: churn the pcp too */
		start_burst(SRC_ESCA);
}

/* ---------- triggers ---------- */

static void trigger_deep(int src)
{
	unsigned long fl;
	int accept = 1;

	spin_lock_irqsave(&t_lock, fl);
	/* NE probes obey the cooldown; writer evidence (whit) and explicit
	 * human/boot triggers always pass */
	if (src == SRC_NEPROBE &&
	    last_trig_ns && ktime_get_ns() - last_trig_ns < (u64)cool_s * 1000000000ULL) {
		suppressed++;
		accept = 0;
	}
	if (accept) {
		pend_deep = 1;
		pend_src = src;
		episodes++;
	}
	spin_unlock_irqrestore(&t_lock, fl);
	if (accept)
		wake_up_interruptible(&dc_wait);
}

static void start_burst(int src)
{
	unsigned long fl;

	spin_lock_irqsave(&t_lock, fl);
	if (!burst_run) {
		bursts++;
		b_empty = 0;
		b_ms_last = ktime_get_ns() / 1000000;
		ring_push("burst", src, 0, 0);
	}
	burst_run = 1;
	burst_deadline = jiffies + msecs_to_jiffies(90000);
	if (!burst_hard)
		burst_hard = jiffies + msecs_to_jiffies(600000);
	spin_unlock_irqrestore(&t_lock, fl);
	wake_up_interruptible(&dc_wait);
}

/* ---------- watch (rolling cursor, D2) ---------- */

static void watch_tick(void)
{
	int i, n;
	unsigned long fl;
	int whit_now = 0;

	spin_lock_irqsave(&c_lock, fl);
	if (ccount > 0) {
		n = ccount - watch_pos;
		if (n > 256)
			n = 256;
		for (i = 0; i < n; i++) {
			struct cent *c = &ctab[(watch_pos + i) % ccount];
			u64 d = tail_digest(c->page);

			if (d && d != c->tail) {
				c->tail = d;
				whits++;
				whit_now++;
			}
		}
		watch_pos = (watch_pos + n) % ccount;
	}
	spin_unlock_irqrestore(&c_lock, fl);
	if (whit_now) {
		last_src = SRC_WHIT;
		trigger_deep(SRC_WHIT);	/* T-a: writer is live on held pages */
		start_burst(SRC_WHIT);
	}
}

/* ---------- SMP rotation ---------- */

static int next_cpu;

static void rotate_cpu(void)
{
	cpumask_t mask;
	int n = num_online_cpus();

	if (n < 2)
		return;
	next_cpu = (next_cpu + 1) % n;
	cpumask_clear(&mask);
	cpumask_set_cpu(next_cpu, &mask);
	set_cpus_allowed_ptr(current, &mask);
}

/* ---------- kthread ---------- */

static int dc_main(void *arg)
{
	unsigned long next_patrol = jiffies;

	if (warmup) {
		rotate_cpu();
		run_deep(SRC_BOOT);	/* T-c: drain the cross-reboot stock */
		start_burst(SRC_BOOT);
	}
	while (!kthread_should_stop()) {
		unsigned long fl;
		int d, src, b_act;

		spin_lock_irqsave(&t_lock, fl);
		d = pend_deep;
		src = pend_src;
		pend_deep = 0;
		b_act = burst_run && time_before(jiffies, burst_deadline);
		if (burst_run && !b_act) {	/* window closed */
			burst_run = 0;
			burst_hard = 0;
			b_ms_last = ktime_get_ns() / 1000000 - b_ms_last;
			if (b_ms_last > b_ms_max)
				b_ms_max = b_ms_last;
		}
		spin_unlock_irqrestore(&t_lock, fl);

		if (d) {
			rotate_cpu();
			run_deep(src);
			continue;
		}
		if (b_act) {
			int c;

			rotate_cpu();
			c = run_sweep();
			b_sweeps++;
			b_clamped += c;
			watch_tick();
			spin_lock_irqsave(&t_lock, fl);
			if (c > 0) {	/* productive: extend, hard cap rules */
				if (time_before(burst_deadline,
						burst_hard - msecs_to_jiffies(30000)))
					burst_deadline = jiffies + msecs_to_jiffies(30000);
				b_empty = 0;
			} else if (++b_empty >= 3) {
				burst_run = 0;
				burst_hard = 0;
				b_ms_last = ktime_get_ns() / 1000000 - b_ms_last;
				if (b_ms_last > b_ms_max)
					b_ms_max = b_ms_last;
			}
			spin_unlock_irqrestore(&t_lock, fl);
			continue;	/* back-to-back inside burst */
		}
		if (time_after_eq(jiffies, next_patrol)) {
			rotate_cpu();
			run_sweep();
			watch_tick();
			next_patrol = jiffies + (unsigned long)
				(period_s > 0 ? period_s : 120) * HZ;
			continue;
		}
		watch_tick();
		wait_event_interruptible_timeout(dc_wait,
			kthread_should_stop() ||
			READ_ONCE(pend_deep) ||
			(burst_run && time_before(jiffies, burst_deadline)),
			5 * HZ);
	}
	return 0;
}

/* ---------- proc v2 ---------- */

static char pbuf[4096];
static int pbuf_len, pbuf_ready;

static int dc_fill(void)
{
	int len = 0, i;
	unsigned long fl;

	spin_lock_irqsave(&c_lock, fl);
	len += scnprintf(pbuf + len, sizeof(pbuf) - len,
		"dpclamp v1.3 sweeps=%llu alloced=%llu clamped=%llu freed=%llu "
		"whits=%llu held=%d/%d idle=%d sweep_us=%llu\n",
		sweeps, alloced, clamped, freed_ok, whits, ccount, cap,
		idle_sweeps, sweep_us_last);
	spin_unlock_irqrestore(&c_lock, fl);
	len += scnprintf(pbuf + len, sizeof(pbuf) - len,
		"deep deeps=%llu heads=%llu walked=%llu cands=%llu keptgrab=%llu "
		"grabbed=%llu ms_last=%llu ms_max=%llu lockus_last=%llu lockus_max=%llu\n",
		deeps, d_heads, d_walked, d_cands, clamped, d_grabbed,
		d_ms_last, d_ms_max, d_lockus_last, d_lockus_max);
	spin_lock_irqsave(&t_lock, fl);
	len += scnprintf(pbuf + len, sizeof(pbuf) - len,
		"burst bursts=%llu sweeps=%llu clamped=%llu ms_last=%llu "
		"ms_max=%llu active=%d\n",
		bursts, b_sweeps, b_clamped, b_ms_last, b_ms_max, burst_run);
	spin_unlock_irqrestore(&t_lock, fl);
	len += scnprintf(pbuf + len, sizeof(pbuf) - len,
		"trig episodes=%llu suppressed=%llu last_src=%s last_ns=%llu\n",
		episodes, suppressed, last_src >= 0 ? src_name[last_src] : "-",
		last_trig_ns);
	len += scnprintf(pbuf + len, sizeof(pbuf) - len, "ring\n");
	for (i = 0; i < ring_n; i++) {
		int idx = (ring_i - ring_n + i + RINGN * 2) % RINGN;

		len += scnprintf(pbuf + len, sizeof(pbuf) - len, "%s\n",
				 ring_q[idx]);
	}
	return len;
}

static ssize_t dc_read(struct file *f, char __user *ub, size_t n, loff_t *off)
{
	int len, chunk, r;

	if (pbuf_ready && *off >= pbuf_len)
		return 0;
	if (*off == 0) {
		pbuf_len = dc_fill();
		pbuf_ready = 1;
	}
	chunk = pbuf_len - (int)*off;
	if (chunk <= 0)
		return 0;
	if (chunk > (int)n)
		chunk = n;
	r = copy_to_user(ub, pbuf + *off, chunk);
	if (r)
		return -EFAULT;
	*off += chunk;
	if (*off >= pbuf_len)
		pbuf_ready = 0;
	return chunk;
}

static ssize_t dc_write(struct file *f, const char __user *ub, size_t n, loff_t *off)
{
	char buf[16];
	size_t m = n > sizeof(buf) - 1 ? sizeof(buf) - 1 : n;

	if (copy_from_user(buf, ub, m))
		return -EFAULT;
	buf[m] = 0;
	if (!strncmp(buf, "deep", 4))
		trigger_deep(SRC_NEPROBE);	/* NE probe path (cooled) */
	else if (!strncmp(buf, "force", 5))
		trigger_deep(SRC_MANUAL);	/* bypass cooldown */
	else if (!strncmp(buf, "burst", 5))
		start_burst(SRC_MANUAL);
	else if (!strncmp(buf, "warmup", 6)) {
		trigger_deep(SRC_MANUAL);
		start_burst(SRC_MANUAL);
	} else
		return -EINVAL;
	return n;
}

static loff_t dc_lseek(struct file *f, loff_t off, int whence) { return 0; }

static const struct proc_ops dc_ops = {
	.proc_read = dc_read,
	.proc_write = dc_write,
	.proc_lseek = dc_lseek,
};

static int __init dpclamp_init(void)
{
	int err;

	ctab = kcalloc(cap, sizeof(*ctab), GFP_KERNEL);
	if (!ctab)
		return -ENOMEM;
	proc_create("dpclamp", 0666, NULL, &dc_ops);
	dct = kthread_run(dc_main, NULL, "dpclampd");
	if (IS_ERR(dct)) {
		err = PTR_ERR(dct);
		dct = NULL;
		remove_proc_entry("dpclamp", NULL);
		kfree(ctab);
		return err;
	}
	pr_info("dpclamp: v1.3 ready (patrol=%ds batch=%d warmup=%d)\n",
		period_s, batch, warmup);
	return 0;
}

static void __exit dpclamp_exit(void)
{
	int i;

	remove_proc_entry("dpclamp", NULL);	/* no new triggers */
	if (dct) {
		wake_up_interruptible(&dc_wait);
		kthread_stop(dct);	/* waits out an in-flight deep (<=1s) */
	}
	spin_lock(&c_lock);
	for (i = 0; i < ccount; i++)
		put_page(ctab[i].page);
	ccount = 0;
	spin_unlock(&c_lock);
	kfree(ctab);
	pr_info("dpclamp: unloaded clamped=%llu whits=%llu deeps=%llu\n",
		clamped, whits, deeps);
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
