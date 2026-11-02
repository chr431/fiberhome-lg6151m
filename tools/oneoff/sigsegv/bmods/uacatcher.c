// SPDX-License-Identifier: GPL-2.0
// uacatcher.ko v1.0 -- D20: capture mt_wifi's __arch_copy_to_user call sites.
//
// Goal: the 32B record family {u32 X, 0, u32 len, __be32 ip, 0...} lands on
// user stack VAs (topva=0x4e0/spva=0xb0). N2 static analysis narrowed the
// write surface to the 12 __arch_copy_to_user call sites inside mt_wifi.ko
// (5 of them in loops, length taken from a register). This module replaces
// each `bl __arch_copy_to_user` with `b stub_i`; the stub enters a common
// trampoline which
//   1. saves x0..x7 (the copy arguments and scratch),
//   2. calls uac_probe(dst=x0, src=x1, n=x2, site=x3, lr=x30) in C,
//   3. restores x0..x7 and performs the ORIGINAL call by branching to the
//      runtime __arch_copy_to_user address (blr), then
//   4. returns to site+4 with x30=site+4, exactly like the displaced `bl`.
// The probe records (dst, len, src, src[0..31], site, caller lr, pid, ts)
// into a per-cpu ring when len <= 64 or dst lies in the current task's user
// stack range; every call is counted per site before filtering.
//
// Why not hook __arch_copy_to_user itself: ptwalk measured the device page
// table and the vmlinux text is PMD-mapped (pmd_leaf=1), which the PTE-flip
// primitive refuses; mt_wifi's module text is PTE-mapped and already proven
// by tuphook v1.4/v1.5.
//
// Safety posture (S0: any oops = forced reboot):
//   - every site is verified at init: instruction is `bl`, the 3 words before
//     it match the pinned mt_wifi build byte for byte, and the decoded target
//     is either the given __arch_copy_to_user or inside mt_wifi's text;
//   - the target's first word must be `add x5,x0,x2` (0x8b020005);
//   - source reads use copy_from_kernel_nofault (extable-fixed, no oops);
//   - the probe is a normal C function; the trampoline uses an 64-byte stack
//     frame below the caller's SP and restores SP before the call;
//   - install patches the pool first, then one site at a time; every write is
//     a 4-byte aligned atomic store under stop_machine + icache maintenance;
//   - uninstall restores all 12 sites and verifies the readback.
//
// Module params:
//   base=0x...    mt_wifi .text runtime base (required)
//   target=0x...  __arch_copy_to_user runtime address (required)
//   dryrun=1      locate + verify + decode only, patch nothing
//   maxread=N     records printed per cpu (default 64, cap 512)
//
// See REVIEW-uacatcher.md and 05_LOG/2026-11-03-03-d20-uaccess32-catcher.md.
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/printk.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/mm.h>
#include <linux/mm_types.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/pid.h>
#include <linux/atomic.h>
#include <linux/stop_machine.h>
#include <linux/percpu.h>
#include <linux/cpumask.h>
#include <linux/smp.h>
#include <linux/delay.h>
#include <linux/string.h>
#include <linux/kallsyms.h>
#include <linux/types.h>
#include <asm/pgtable.h>
#include <asm/memory.h>
#include <asm/processor.h>
#include <asm/barrier.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("uacatcher: mt_wifi __arch_copy_to_user call-site catcher (D20)");
MODULE_AUTHOR("chr431");

#define UAC_NSITE	12
#define UAC_NREC	128
#define UAC_RECSZ	96
#define UAC_HEAD_OFF	(UAC_NREC * UAC_RECSZ)	/* 0xC000 */
#define UAC_NM		256

/* mt_wifi.ko (md5 5e124c24bbd7beba3ccc7fc89554702a) .text offsets of the 12
 * `bl __arch_copy_to_user` instructions, and the three words preceding each
 * (csdb / mov x2,.. / mov x1,..) used as a build fingerprint. */
static const u32 uac_site_off[UAC_NSITE] = {
	0x025bf4, 0x05b7e0, 0x13c360, 0x1eac44, 0x1f1d94, 0x1f577c,
	0x1f9864, 0x237430, 0x2976d8, 0x2b4738, 0x2dc204, 0x33bc64,
};
static const u32 uac_site_sig[UAC_NSITE][3] = {
	{ 0xd503229f, 0xaa0403e2, 0xaa0603e1 },
	{ 0xd503229f, 0xaa1503e1, 0xd2800102 },
	{ 0xd503229f, 0xaa0403e2, 0xaa0603e1 },
	{ 0xd503229f, 0xaa0403e2, 0xaa0603e1 },
	{ 0xd503229f, 0xaa1303e2, 0xaa1b03e1 },
	{ 0xd503229f, 0xaa0403e2, 0xaa0603e1 },
	{ 0xd503229f, 0xaa1303e2, 0xaa1503e1 },
	{ 0xd503229f, 0xaa0403e2, 0xaa0603e1 },
	{ 0xd503229f, 0xaa1503e2, 0xaa1903e1 },
	{ 0xd503229f, 0xaa0403e2, 0xaa0603e1 },
	{ 0x9a9f0080, 0xd503229f, 0xaa0503e1 },
	{ 0xd503229f, 0x9100abe1, 0xd2801ec2 },
};

#define INS_BL_MASK	0xfc000000u
#define INS_BL		0x94000000u
#define INS_TGT_FIRST	0x8b020005u	/* add x5, x0, x2 */

static unsigned long uac_base;
module_param_named(base, uac_base, ulong, 0444);
MODULE_PARM_DESC(uac_base, "mt_wifi .text runtime base");
static unsigned long uac_target;
module_param_named(target, uac_target, ulong, 0444);
MODULE_PARM_DESC(uac_target, "__arch_copy_to_user runtime address");
static int dryrun;
module_param(dryrun, int, 0444);
MODULE_PARM_DESC(dryrun, "1 = verify only, patch nothing");
static int maxread = 64;
module_param(maxread, int, 0444);
MODULE_PARM_DESC(maxread, "records printed per cpu (default 64, cap 512)");

/* record flags */
#define UAC_F_STACK	0x01	/* dst inside current task's stack range */
#define UAC_F_SMALL	0x02	/* len <= 64 */
#define UAC_F_DATAFAULT	0x04	/* src[32] read faulted (partial data) */
#define UAC_F_SITE_OOR	0x08	/* site index out of range (never) */

struct uac_rec {
	u64 dst;
	u64 len;
	u64 src;
	u64 site;	/* 0..11 */
	u64 lr;		/* caller's x30 at the call site */
	u64 ts;		/* cntvct_el0 */
	u8  data[32];
	u32 pid;
	u32 flags;
	u64 pad;
};

struct uac_ring {
	struct uac_rec recs[UAC_NREC];
	u64 head;		/* (idx<<1) | nested_guard */
	u64 calls[UAC_NSITE];	/* every call counted, before filtering */
	u64 recd;
};

static struct uac_ring __percpu *rings;

/* ---- stubs + common trampoline + per-site pool ---- */
asm(
".pushsection .text\n"
".balign 4096\n"
".globl uac_stub0\n"
"uac_stub0:\n"
"	mov	x3, #0\n"
"	b	uac_common\n"
".globl uac_stub1\n"
"uac_stub1:\n"
"	mov	x3, #1\n"
"	b	uac_common\n"
".globl uac_stub2\n"
"uac_stub2:\n"
"	mov	x3, #2\n"
"	b	uac_common\n"
".globl uac_stub3\n"
"uac_stub3:\n"
"	mov	x3, #3\n"
"	b	uac_common\n"
".globl uac_stub4\n"
"uac_stub4:\n"
"	mov	x3, #4\n"
"	b	uac_common\n"
".globl uac_stub5\n"
"uac_stub5:\n"
"	mov	x3, #5\n"
"	b	uac_common\n"
".globl uac_stub6\n"
"uac_stub6:\n"
"	mov	x3, #6\n"
"	b	uac_common\n"
".globl uac_stub7\n"
"uac_stub7:\n"
"	mov	x3, #7\n"
"	b	uac_common\n"
".globl uac_stub8\n"
"uac_stub8:\n"
"	mov	x3, #8\n"
"	b	uac_common\n"
".globl uac_stub9\n"
"uac_stub9:\n"
"	mov	x3, #9\n"
"	b	uac_common\n"
".globl uac_stub10\n"
"uac_stub10:\n"
"	mov	x3, #10\n"
"	b	uac_common\n"
".globl uac_stub11\n"
"uac_stub11:\n"
"	mov	x3, #11\n"
"	b	uac_common\n"
".globl uac_common\n"
"uac_common:\n"
"	sub	sp, sp, #80\n"
"	stp	x0, x1, [sp]\n"
"	stp	x2, x3, [sp, #16]\n"
"	stp	x4, x5, [sp, #32]\n"
"	stp	x6, x7, [sp, #48]\n"
"	str	x19, [sp, #64]\n"
"	mov	x4, x30\n"
"	mov	x19, x3\n"
"	bl	uac_probe\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x3, [sp, #16]\n"
"	ldp	x4, x5, [sp, #32]\n"
"	ldp	x6, x7, [sp, #48]\n"
"	adr	x16, uac_pool\n"
"	add	x16, x16, x19, lsl #4\n"
"	ldr	x17, [x16]\n"
"	blr	x17\n"
"	adr	x16, uac_pool\n"
"	add	x16, x16, x19, lsl #4\n"
"	ldr	x17, [x16, #8]\n"
"	mov	x30, x17\n"
"	ldr	x19, [sp, #64]\n"
"	add	sp, sp, #80\n"
"	br	x17\n"
".balign 16\n"
".popsection\n"
);

extern char uac_stub0[], uac_stub1[], uac_stub2[], uac_stub3[];
extern char uac_stub4[], uac_stub5[], uac_stub6[], uac_stub7[];
extern char uac_stub8[], uac_stub9[], uac_stub10[], uac_stub11[];
extern char uac_common[];
u64 uac_pool[2 * UAC_NSITE] __attribute__((used));

static char * const uac_stub[UAC_NSITE] = {
	uac_stub0, uac_stub1, uac_stub2, uac_stub3, uac_stub4, uac_stub5,
	uac_stub6, uac_stub7, uac_stub8, uac_stub9, uac_stub10, uac_stub11,
};

static bool installed;
static u32 uac_orig[UAC_NSITE];	/* original bl words */
static u32 uac_patched[UAC_NSITE];	/* b words we wrote */
static char uac_sitename[UAC_NSITE][UAC_NM];
static char uac_siteinfo[UAC_NSITE][160];

/* ------------------------------------------------------------------ */
/* probe: runs on every hooked call, before the original copy          */
/* ------------------------------------------------------------------ */
static inline bool uac_is_stack(u64 dst)
{
	struct mm_struct *mm;
	unsigned long sp;

	if (dst >= TASK_SIZE_MAX)
		return false;
	mm = current->mm;
	if (!mm)
		return false;
	sp = mm->start_stack;
	if (!sp)
		return false;
	if (dst > sp + 0x10000)
		return false;
	if (dst + 0x1000 < sp - 0x800000)
		return false;
	return true;
}

__attribute__((used))
noinline void uac_probe(u64 dst, u64 src, u64 n, u64 site, u64 lr)
{
	struct uac_ring *r;
	struct uac_rec *rec;
	u64 head, idx, ts;
	u32 flags = 0;
	bool small = (n <= 64);
	bool stack = uac_is_stack(dst);

	r = this_cpu_ptr(rings);
	if (site < UAC_NSITE)
		r->calls[site]++;
	if (!small && !stack)
		return;
	if (small)
		flags |= UAC_F_SMALL;
	if (stack)
		flags |= UAC_F_STACK;
	head = READ_ONCE(r->head);
	if (head & 1)		/* nested entry: skip recording */
		return;
	WRITE_ONCE(r->head, head + 3);
	idx = (head >> 1) & (UAC_NREC - 1);	/* slot of THIS record */
	rec = &r->recs[idx];
	rec->dst = dst;
	rec->len = n;
	rec->src = src;
	rec->site = site;
	rec->lr = lr;
	asm volatile("mrs %0, cntvct_el0" : "=r"(ts));
	rec->ts = ts;
	rec->pid = current->pid;
	{
		u64 *d = (u64 *)rec->data;

		d[0] = 0; d[1] = 0; d[2] = 0; d[3] = 0;
	}
	if (copy_from_kernel_nofault(rec->data, (const void *)src, 32))
		flags |= UAC_F_DATAFAULT;
	rec->flags = flags;
	r->recd++;
	WRITE_ONCE(r->head, (head + 3) & ~1ULL);
}

/* ------------------------------------------------------------------ */
/* page-table window + patch primitive (same as tuphook, proven)       */
/* ------------------------------------------------------------------ */
struct pte_flip {
	pte_t *ptep;
	pte_t val;
	unsigned long page;
};

static int uac_get_kernel_pgd(pgd_t **out)
{
	unsigned long t, pa;
	pgd_t *pgd;

	asm volatile("mrs %0, ttbr1_el1" : "=r"(t));
	pa = t & 0x0000fffffffff000UL;
	if (!pa)
		return -ENODEV;
	pgd = (pgd_t *)__va(pa);
	if (((unsigned long)pgd & (PAGE_SIZE - 1)) ||
	    (unsigned long)pgd < PAGE_OFFSET ||
	    (unsigned long)pgd >= VMALLOC_START)
		return -EINVAL;
	*out = pgd;
	return 0;
}

static int uac_walk_pte(unsigned long va, pte_t **out)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;

	if (uac_get_kernel_pgd(&pgd))
		return -ENODEV;
	pgd = pgd + pgd_index(va);
	if (pgd_none(READ_ONCE(*pgd)) || pgd_bad(READ_ONCE(*pgd)))
		return -ENOENT;
	p4d = p4d_offset(pgd, va);
	if (p4d_none(READ_ONCE(*p4d)) || p4d_bad(READ_ONCE(*p4d)))
		return -ENOENT;
	pud = pud_offset(p4d, va);
	if (pud_none(READ_ONCE(*pud)) || pud_bad(READ_ONCE(*pud)))
		return -ENOENT;
	if (pud_leaf(READ_ONCE(*pud)))
		return -EINVAL;
	pmd = pmd_offset(pud, va);
	if (pmd_none(READ_ONCE(*pmd)))
		return -ENOENT;
	if (pmd_leaf(READ_ONCE(*pmd)))
		return -EINVAL;
	pte = pte_offset_kernel(pmd, va);
	if (!pte_present(READ_ONCE(*pte)))
		return -ENOENT;
	*out = pte;
	return 0;
}

static atomic_t flip_cpus;

static int uac_flip_cb(void *arg)
{
	struct pte_flip *f = arg;

	if (atomic_inc_return(&flip_cpus) == 1) {
		WRITE_ONCE(*f->ptep, f->val);
		dsb(ish);
		atomic_inc(&flip_cpus);
	} else {
		while (atomic_read(&flip_cpus) <= num_online_cpus())
			cpu_relax();
	}
	asm volatile("dsb ishst\n"
		     "tlbi vaale1is, %0\n"
		     "dsb ish\n"
		     "isb" :: "r"(f->page >> 12) : "memory");
	return 0;
}

static int uac_set_pte(pte_t *ptep, pte_t val, unsigned long page)
{
	struct pte_flip f = { .ptep = ptep, .val = val, .page = page };

	atomic_set(&flip_cpus, 0);
	return stop_machine(uac_flip_cb, &f, NULL);
}

struct patch_item {
	void *addr;
	u32 insn;
};

struct patch_req {
	struct patch_item items[8];
	int n;
};

static atomic_t patch_cpus;

static int uac_patch_cb(void *arg)
{
	struct patch_req *r = arg;
	int i;

	if (atomic_inc_return(&patch_cpus) == 1) {
		for (i = 0; i < r->n; i++)
			WRITE_ONCE(*(u32 *)r->items[i].addr, r->items[i].insn);
		dsb(ish);
		atomic_inc(&patch_cpus);
	} else {
		while (atomic_read(&patch_cpus) <= num_online_cpus())
			cpu_relax();
	}
	for (i = 0; i < r->n; i++)
		asm volatile("dc cvau, %0\n"
			     "dsb ish\n"
			     "ic ivau, %0\n"
			     "dsb ish\n"
			     "isb" :: "r"(r->items[i].addr) : "memory");
	return 0;
}

static int uac_patch_words(unsigned long page, struct patch_item *items, int n)
{
	pte_t *ptep, orig;
	struct patch_req r;
	int rc, i;

	if (n < 1 || n > 8)
		return -EINVAL;
	for (i = 0; i < n; i++)
		if (((unsigned long)items[i].addr & PAGE_MASK) != page)
			return -EINVAL;
	rc = uac_walk_pte(page, &ptep);
	if (rc)
		return rc;
	orig = READ_ONCE(*ptep);
	if (!pte_write(orig)) {
		rc = uac_set_pte(ptep, pte_mkwrite(orig), page);
		if (rc)
			return rc;
	}
	memset(&r, 0, sizeof(r));
	r.n = n;
	for (i = 0; i < n; i++)
		r.items[i] = items[i];
	atomic_set(&patch_cpus, 0);
	rc = stop_machine(uac_patch_cb, &r, NULL);
	if (!pte_write(orig))
		uac_set_pte(ptep, orig, page);
	return rc;
}

/* ------------------------------------------------------------------ */
/* site verification                                                   */
/* ------------------------------------------------------------------ */
static u32 uac_mkb(s64 delta)
{
	return 0x14000000u | (((u64)delta >> 2) & 0x03ffffffu);
}

static unsigned long uac_b_target(unsigned long site, u32 insn)
{
	s64 d = (s64)(insn & 0x03ffffffu);

	if (d & 0x02000000)
		d -= 0x04000000;
	return (unsigned long)((s64)site + d * 4);
}

static int uac_verify(void)
{
	int i, rc = 0;

	if (!uac_base || !uac_target) {
		pr_err("uacatcher: base/target params required\n");
		return -EINVAL;
	}
	if (READ_ONCE(*(u32 *)uac_target) != INS_TGT_FIRST) {
		pr_err("uacatcher: target %lx first word %08x != %08x\n",
		       uac_target, READ_ONCE(*(u32 *)uac_target), INS_TGT_FIRST);
		return -EINVAL;
	}
	for (i = 0; i < UAC_NSITE; i++) {
		unsigned long a = uac_base + uac_site_off[i];
		u32 insn = READ_ONCE(*(u32 *)a);
		u32 w1 = READ_ONCE(*(u32 *)(a - 4));
		u32 w2 = READ_ONCE(*(u32 *)(a - 8));
		u32 w3 = READ_ONCE(*(u32 *)(a - 12));
		unsigned long tgt;
		char nm[UAC_NM] = "?";

		if ((insn & INS_BL_MASK) != INS_BL) {
			pr_err("uacatcher: site%d %lx insn %08x is not bl\n",
			       i, a, insn);
			rc = -EINVAL;
			continue;
		}
		if (w1 != uac_site_sig[i][2] || w2 != uac_site_sig[i][1] ||
		    w3 != uac_site_sig[i][0]) {
			pr_err("uacatcher: site%d %lx signature mismatch %08x/%08x/%08x\n",
			       i, a, w1, w2, w3);
			rc = -EINVAL;
			continue;
		}
		tgt = uac_b_target(a, insn);
		if (tgt != uac_target &&
		    (tgt < uac_base || tgt >= uac_base + 0x800000)) {
			pr_err("uacatcher: site%d %lx bl target %lx implausible\n",
			       i, a, tgt);
			rc = -EINVAL;
			continue;
		}
		sprint_symbol(nm, a + 4);
		strscpy(uac_sitename[i], nm, UAC_NM);
		scnprintf(uac_siteinfo[i], sizeof(uac_siteinfo[i]),
			  "site%-2d off=0x%06x ret=%016lx bl_tgt=%016lx %s",
			  i, uac_site_off[i], a + 4, tgt, nm);
		pr_info("uacatcher: %s\n", uac_siteinfo[i]);
	}
	return rc;
}

/* ------------------------------------------------------------------ */
/* install / remove                                                    */
/* ------------------------------------------------------------------ */
static int uac_install(void)
{
	struct patch_item items[8];
	unsigned long ppage = (unsigned long)uac_pool & PAGE_MASK;
	int i, rc;

	/* 1. fill the per-site pool: {target, ret} x 12.  The pool is a
	 * writable .data array (not .text): the first live defect was a
	 * plain C store into a RO .text pool; the second was a pool whose
	 * runtime address did not match the C symbol (readback read foreign
	 * memory).  A .data array removes both failure modes. */
	for (i = 0; i < UAC_NSITE; i++) {
		uac_pool[i * 2] = uac_target;
		uac_pool[i * 2 + 1] = uac_base + uac_site_off[i] + 4;
	}
	for (i = 0; i < UAC_NSITE; i++) {
		if (uac_pool[i * 2] != uac_target ||
		    uac_pool[i * 2 + 1] != uac_base + uac_site_off[i] + 4) {
			pr_err("uacatcher: pool%d write failed\n", i);
			return -EIO;
		}
	}
	/* 2. one site at a time: bl -> b stub_i */
	for (i = 0; i < UAC_NSITE; i++) {
		unsigned long a = uac_base + uac_site_off[i];
		s64 d = (s64)(unsigned long)uac_stub[i] - (s64)a;

		if (d < -(1 << 27) || d >= (1 << 27)) {
			pr_err("uacatcher: site%d B out of range\n", i);
			return -ERANGE;
		}
		uac_orig[i] = READ_ONCE(*(u32 *)a);
		uac_patched[i] = uac_mkb(d);
		if (uac_b_target(a, uac_patched[i]) != (unsigned long)uac_stub[i]) {
			pr_err("uacatcher: site%d branch self-check failed\n", i);
			return -EINVAL;
		}
		items[0].addr = (void *)a;
		items[0].insn = uac_patched[i];
		rc = uac_patch_words(a & PAGE_MASK, items, 1);
		if (rc) {
			pr_err("uacatcher: site%d patch failed: %d\n", i, rc);
			return rc;
		}
	}
	/* 3. readback */
	for (i = 0; i < UAC_NSITE; i++) {
		unsigned long a = uac_base + uac_site_off[i];

		if (READ_ONCE(*(u32 *)a) != uac_patched[i]) {
			pr_err("uacatcher: site%d readback mismatch\n", i);
			return -EIO;
		}
	}
	installed = true;
	return 0;
}

static void uac_uninstall(void)
{
	int i;

	if (!installed)
		return;
	for (i = 0; i < UAC_NSITE; i++) {
		unsigned long a = uac_base + uac_site_off[i];
		struct patch_item it;

		if (READ_ONCE(*(u32 *)a) != uac_patched[i]) {
			pr_warn("uacatcher: site%d changed by someone else, skip\n", i);
			continue;
		}
		it.addr = (void *)a;
		it.insn = uac_orig[i];
		if (uac_patch_words(a & PAGE_MASK, &it, 1))
			pr_err("uacatcher: site%d restore failed\n", i);
	}
	for (i = 0; i < UAC_NSITE; i++)
		if (READ_ONCE(*(u32 *)(uac_base + uac_site_off[i])) != uac_orig[i])
			pr_err("uacatcher: site%d restore readback mismatch\n", i);
	pr_info("uacatcher: 12 sites restored to original bl\n");
	installed = false;
}

/* ------------------------------------------------------------------ */
/* /proc/uacatcher                                                     */
/* ------------------------------------------------------------------ */
static struct proc_dir_entry *uac_pe;

static int uac_show(struct seq_file *m, void *v)
{
	unsigned int k = (maxread <= 0) ? 64 : (maxread > UAC_NREC ? UAC_NREC : maxread);
	u64 freq = 0, now = 0;
	int cpu, i;

	asm volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	asm volatile("mrs %0, cntvct_el0" : "=r"(now));
	seq_printf(m, "uacatcher v1.0: %s base=%016lx target=%016lx\n",
		   installed ? "PATCHED" : (dryrun ? "dryrun" : "locate-only"),
		   uac_base, uac_target);
	seq_printf(m, "clock: cntfrq=%llu now=%llu\n", freq, now);
	for (i = 0; i < UAC_NSITE; i++)
		seq_printf(m, "  %s\n", uac_siteinfo[i]);
	for_each_online_cpu(cpu) {
		struct uac_ring *r = per_cpu_ptr(rings, cpu);
		u64 head = READ_ONCE(r->head);
		u64 cnt = head >> 1;
		unsigned int show = cnt < k ? (unsigned int)cnt : k;
		unsigned int j;

		seq_printf(m, "cpu%d: recorded=%llu guard=%llu recd=%llu\n",
			   cpu, cnt, head & 1, READ_ONCE(r->recd));
		seq_printf(m, "  calls:");
		for (i = 0; i < UAC_NSITE; i++)
			seq_printf(m, " %d=%llu", i, READ_ONCE(r->calls[i]));
		seq_printf(m, "\n");
		for (j = 0; j < show; j++) {
			u64 seq = cnt - 1 - j;
			struct uac_rec *rec = &r->recs[seq & (UAC_NREC - 1)];
			u64 dst = READ_ONCE(rec->dst);
			u64 len = READ_ONCE(rec->len);
			u64 src = READ_ONCE(rec->src);
			u64 site = READ_ONCE(rec->site);
			u64 lr = READ_ONCE(rec->lr);
			u64 ts = READ_ONCE(rec->ts);
			u32 pid = READ_ONCE(rec->pid);
			u32 fl = READ_ONCE(rec->flags);
			const u8 *d = rec->data;

			seq_printf(m,
				   "  #%llu site=%llu dst=%016llx len=%llu src=%016llx lr=%016llx pid=%u fl=%02x ts=%llu data=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x\n",
				   seq, site, dst, len, src, lr, pid, fl, ts,
				   d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
				   d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15],
				   d[16], d[17], d[18], d[19], d[20], d[21], d[22], d[23],
				   d[24], d[25], d[26], d[27], d[28], d[29], d[30], d[31]);
		}
	}
	return 0;
}

static int uac_open(struct inode *inode, struct file *file)
{
	return single_open(file, uac_show, NULL);
}

static const struct proc_ops uac_pops = {
	.proc_open	= uac_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* ------------------------------------------------------------------ */
static int __init uacatcher_init(void)
{
	int rc, cpu;

	BUILD_BUG_ON(sizeof(struct uac_rec) != UAC_RECSZ);
	BUILD_BUG_ON(offsetof(struct uac_ring, head) != UAC_HEAD_OFF);
	BUILD_BUG_ON(offsetof(struct uac_ring, calls) != UAC_HEAD_OFF + 8);

	rings = alloc_percpu(struct uac_ring);
	if (!rings)
		return -ENOMEM;
	for_each_possible_cpu(cpu)
		memset(per_cpu_ptr(rings, cpu), 0, sizeof(struct uac_ring));

	rc = uac_verify();
	if (rc)
		goto out_free;

	if (!dryrun) {
		rc = uac_install();
		if (rc) {
			uac_uninstall();
			goto out_free;
		}
		pr_info("uacatcher: INSTALLED 12/12 sites\n");
	} else {
		pr_info("uacatcher: DRYRUN verify complete, nothing patched\n");
	}

	uac_pe = proc_create("uacatcher", 0444, NULL, &uac_pops);
	if (!uac_pe) {
		rc = -ENOMEM;
		goto out_uninstall;
	}
	return 0;
out_uninstall:
	uac_uninstall();
out_free:
	free_percpu(rings);
	rings = NULL;
	return rc;
}

static void __exit uacatcher_exit(void)
{
	uac_uninstall();
	if (uac_pe)
		proc_remove(uac_pe);
	if (rings) {
		free_percpu(rings);
		rings = NULL;
	}
	pr_info("uacatcher: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(uacatcher_init);
module_exit(uacatcher_exit);

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
