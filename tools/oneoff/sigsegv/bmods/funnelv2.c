// SPDX-License-Identifier: GPL-2.0
// funnelv2.ko v2.0 -- D27: embedded-record scan at the single uaccess funnel
// __arch_copy_to_user (vmlinux .text 0xffffffc00843b680, first insn
// `add x5,x0,x2` = 05 00 02 8b).
//
// Why v2 exists (S1-sw-gaps.md 4.3): D23 v1 only inspected len==32/16 with the
// record at src offset 0.  The D21 crash geometry says the 32B record sits at
// VA = sp_call-0xb0, i.e. inside the callee's vararg save area; a writer that
// copies a larger structure to the user stack would carry the record at some
// 16B-multiple offset o>0.  v2 scans every len in [16,0x1000], every 16B
// offset aligned to the destination (o0 = (-dst)&0xf), quick-filters with
// q1==0 && q3==0, then applies the family-B content test.
//
// Patch primitive: unchanged from funnelcatcher v1 (vmlinux .text is
// PMD-mapped RO and the linear alias is RO too, so we walk the kernel page
// table, take pfn_to_page() and build a private writable alias with
// vmap(1 page, PAGE_KERNEL); the 4-byte `b <trampoline>` is written through
// that alias inside stop_machine, dc civac + ic ivau on the image VA on every
// CPU, vunmap after restore; restore is read back, 3 attempts).
//
// Trampoline: the site's first instruction is displaced.  The fast path is
// two compares (len < 16 || len > 0x1000 -> re-execute displaced insn and
// branch back to site+4).  Qualifying calls enter the C scanner:
//   - dst must be a user VA (dst < 1<<44, dst+len no wrap);
//   - stack_hint = dst in [current->mm->start_stack-8MB, start_stack+0x1000);
//   - stack_near = dst in [start_stack-256KB, start_stack+0x1000);
//   - non-stack dst with len>0x100 is sampled 1:16 (bounded cost);
//   - every 16B step: q0..q3 read via copy_from_kernel_nofault (chunked
//     0x100B with 16B overlap, so a bad src cannot oops);
//   - quick filter q1==0 && q3==0; family A0B2/B0A2 content recorded;
//     16B-core variant counted separately (exploratory, not recorded);
//   - stack hits -> hot ring (1024/CPU), non-stack -> cold ring (256/CPU);
//   - the first stack family hit per CPU also gets a full <=0x1000B src dump
//     (the per-record ring entry is 128B, so a 4KB copy per record would be
//     20MB; the dump preserves the "whole src" evidence for the decisive hit).
//
// Safety: dryrun=1 locates/verifies/maps RO and writes nothing; branch range
// is checked; alias readback must equal the live site word before patching;
// install/restore run under stop_machine with per-CPU I-cache maintenance;
// module exit sleeps 100ms so in-flight trampoline entries finish.
//
// Module params: site=0x... (default 0xffffffc00843b680), dryrun=1,
// maxread=N (records printed per ring, default 32, cap 256), fulldump=1.
//
// See docs/SIGSEGV/05_LOG/2026-11-03-10-d27-funnelv2.md (prereg).
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/printk.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/mm.h>
#include <linux/mm_types.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/atomic.h>
#include <linux/stop_machine.h>
#include <linux/percpu.h>
#include <linux/cpumask.h>
#include <linux/smp.h>
#include <linux/delay.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/vmalloc.h>
#include <linux/mmzone.h>
#include <linux/kallsyms.h>
#include <asm/pgtable.h>
#include <asm/memory.h>
#include <asm/processor.h>
#include <asm/barrier.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("funnelv2: embedded-record scan at __arch_copy_to_user (D27)");
MODULE_AUTHOR("chr431");

#define FV2_HOT_N		1024
#define FV2_COLD_N		256
#define FV2_HOT_MASK		(FV2_HOT_N - 1)
#define FV2_COLD_MASK		(FV2_COLD_N - 1)
#define FV2_NTRACE		3
#define FV2_NM			256
#define FV2_CHUNK		0x100	/* nofault read granularity */
#define FV2_SCAN_MAX		0x1000	/* per-call scan cap (asm filter) */
#define FV2_STACK_WIDE		0x800000UL	/* 8MB stack band */
#define FV2_STACK_NEAR		0x40000UL	/* 256KB "near" band */
#define FV2_USER_MAX		0x0000100000000000ULL	/* 1<<44, safe user bound */
#define FV2_MAXREC_CALL		8	/* ring records per copy call */
#define FV2_DUMP_SZ		0x1000

/* expected first word of __arch_copy_to_user: add x5, x0, x2 */
#define FV2_ORIG_WORD		0x8b020005u
#define FV2_SITE_DEFAULT	0xffffffc00843b680UL

static unsigned long fv2_site = FV2_SITE_DEFAULT;
module_param_named(site, fv2_site, ulong, 0444);
MODULE_PARM_DESC(fv2_site, "__arch_copy_to_user entry VA");
static int dryrun;
module_param(dryrun, int, 0444);
MODULE_PARM_DESC(dryrun, "1 = verify only, patch nothing");
static int maxread = 32;
module_param(maxread, int, 0444);
MODULE_PARM_DESC(maxread, "records printed per ring per cpu (default 32, cap 256)");
static int fulldump = 1;
module_param(fulldump, int, 0444);
MODULE_PARM_DESC(fulldump, "1 = keep a full <=0x1000B src dump of the first stack hit per cpu");

/* record flags */
#define FV2_F_A0B2	0x0001	/* family B, A0B2 form {A,0,len,ip,0} */
#define FV2_F_B0A2	0x0002	/* family B, B0A2 form {B,0,A',0} */
#define FV2_F_STACK	0x0004	/* dst in [start_stack-8MB, start_stack+0x1000) */
#define FV2_F_NEAR	0x0008	/* dst in [start_stack-256KB, ...) */
#define FV2_F_ASMALL	0x0010	/* A0B2 q0 low32 in [0x1000,0x100000] */
#define FV2_F_DUMPED	0x0020	/* this hit owns the per-cpu full dump */

struct fv2_rec {
	u64 ts;
	u64 lr;
	u64 dst;
	u64 src;
	u64 len;
	u64 off;		/* record offset inside src */
	u64 q0, q1, q2, q3;	/* the matched 32B */
	u64 trace[FV2_NTRACE];	/* fp-chain return addresses */
	u32 pid;
	u32 flags;
	char comm[16];
};

struct fv2_ring {
	struct fv2_rec *recs;
	u64 head;		/* (idx<<1)|guard */
	u64 recd;
	u64 drop;
	u32 n;
	u32 mask;
};

struct fv2_cpu {
	struct fv2_ring hot;
	struct fv2_ring cold;
	struct fv2_rec hot_recs[FV2_HOT_N];
	struct fv2_rec cold_recs[FV2_COLD_N];
	/* fast-path counters (single writer = this CPU) */
	u64 eligible;		/* len in range + user dst */
	u64 nonuser;		/* dst not a user VA */
	u64 scanned;		/* scan actually entered */
	u64 bytes;		/* src bytes read via nofault */
	u64 sampled;		/* non-stack len>0x100 sampled out */
	u64 srcfault;		/* nofault src read failed */
	u64 quick;		/* 16B windows passing q1==0 && q3==0 */
	u64 a0b2;		/* family A0B2 content hits */
	u64 b0a2;		/* family B0A2 content hits */
	u64 core16;		/* exploratory 16B-core {len,ip} hits */
	u64 capped;		/* family hits over FV2_MAXREC_CALL */
	u64 stack_hot;		/* stack_hint calls scanned */
	u64 stack_cold;		/* non-stack calls scanned */
	u64 near_hits;		/* hits with stack_near */
	u64 sample_tick;
	/* first stack family hit: full src dump */
	u64 dump_used;		/* 0=free, 1=valid, 2=attempted+faulted */
	u64 dump_len;
	u64 dump_off;
	u64 dump_dst;
	u64 dump_src;
	u64 dump_lr;
	u64 dump_ts;
	u32 dump_pid;
	u32 dump_flags;
	char dump_comm[16];
	u8 dump[FV2_DUMP_SZ];
};

/* v2.1: __alloc_percpu() rejects any unit > PCPU_MIN_UNIT_SIZE (32 KiB),
 * and struct fv2_cpu is 168,216 B (hot 1024 + cold 256 + 4 KiB dump), so
 * the percpu API cannot carry it (on-device dryrun 2026-11-03: WARN
 * mm/percpu.c "illegal size (168216)" -> -ENOMEM).  Use one vzalloc'd
 * array indexed by CPU instead; ring layout, capacity and
 * single-writer-per-CPU semantics are unchanged. */
static struct fv2_cpu *fv2_cpus;

/* total entries into the trampoline (asm-incremented, rough) */
u64 funnelv2_calls;

/* site+4 target, set at init */
u64 funnelv2_ret __read_mostly;

/* ---- trampoline: displaced insn + inline len filter + C scanner ---- */
asm(
".pushsection .text\n"
".balign 4096\n"
".globl funnelv2_tramp\n"
"funnelv2_tramp:\n"
"	adrp	x15, funnelv2_calls\n"
"	ldr	x16, [x15, :lo12:funnelv2_calls]\n"
"	add	x16, x16, #1\n"
"	str	x16, [x15, :lo12:funnelv2_calls]\n"
"	sub	x15, x2, #16\n"
"	cmp	x15, #0xff0\n"		/* 0x1000 - 16 */
"	b.hi	9f\n"
"	stp	x0, x1, [sp, #-64]!\n"
"	stp	x2, x30, [sp, #16]\n"
"	mov	x3, x30\n"
"	mov	x4, x29\n"
"	bl	funnelv2_cand\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x30, [sp, #16]\n"
"	add	sp, sp, #64\n"
"9:\n"
"	.inst	0x8b020005\n"		/* displaced: add x5, x0, x2 */
"	adrp	x15, funnelv2_ret\n"
"	ldr	x16, [x15, :lo12:funnelv2_ret]\n"
"	br	x16\n"
".balign 16\n"
".popsection\n"
);
extern char funnelv2_tramp[];

static bool fv2_installed;
static bool fv2_vmapped;
static void *fv2_alias;		/* vmap base of the site page */
static unsigned long fv2_alias_off;
static u32 fv2_orig;		/* original 4 bytes */
static u32 fv2_patch;		/* b trampoline */
static unsigned long fv2_pa;	/* site physical address */
static char fv2_sym[FV2_NM];

static __always_inline u64 fv2_ld64(const u8 *p)
{
	u64 v;

	memcpy(&v, p, 8);
	return v;
}

/* ------------------------------------------------------------------ */
/* record path                                                        */
/* ------------------------------------------------------------------ */
static void fv2_unwind(u64 fp, u64 *trace, u32 *n)
{
	int i;

	for (i = 0; i < FV2_NTRACE; i++) {
		u64 next_fp, ret;

		if (!fp || (fp & 7) || fp < 0xffff000000000000ULL)
			break;
		if (copy_from_kernel_nofault(&next_fp, (const void *)fp, 8))
			break;
		if (copy_from_kernel_nofault(&ret, (const void *)(fp + 8), 8))
			break;
		trace[i] = ret;
		(*n)++;
		if (next_fp <= fp)
			break;
		fp = next_fp;
	}
}

/* A0B2: {A, 0, u32 len, __be32 ip, 0}; q1==q3==0 already checked.
 * The IP first octet is data[20] (little-endian u32 length at data[16]). */
static __always_inline int fv2_family_a0b2(u64 q0, u64 q2, const u8 *p,
					   u32 *flags)
{
	u32 l = (u32)q2;
	u8 first = p[20];

	if (l < 0x40 || l > 0x4000)
		return 0;
	if (first == 0 || first == 127 || first >= 224)
		return 0;
	*flags |= FV2_F_A0B2;
	if ((u32)q0 >= 0x1000 && (u32)q0 <= 0x100000)
		*flags |= FV2_F_ASMALL;
	return 1;
}

/* B0A2: {B, 0, u64 A', 0}, A' in [0x1000,0x100000], B != 0 */
static __always_inline int fv2_family_b0a2(u64 q0, u64 q2)
{
	if ((q2 >> 32) != 0)
		return 0;
	if ((u32)q2 < 0x1000 || (u32)q2 > 0x100000)
		return 0;
	return q0 != 0;
}

/* exploratory 16B core: {u32 len, __be32 ip} at a 16B-aligned VA */
static __always_inline int fv2_core16(u64 q0, const u8 *p)
{
	u32 l = (u32)q0;
	u8 first = p[4];

	if (l < 0x40 || l > 0x4000)
		return 0;
	if (first == 0 || first == 127 || first >= 224)
		return 0;
	return 1;
}

struct fv2_hit {
	u64 dst, src, len, off;
	u64 q[4];
	u64 lr, fp;
	u32 flags;
	u8 stack, near;
};

static noinline void fv2_ring_put(struct fv2_cpu *r, struct fv2_ring *rg,
				  const struct fv2_hit *h)
{
	u64 head, idx, ts;
	struct fv2_rec *rec;
	u32 ntrace = 0;

	head = READ_ONCE(rg->head);
	if (head & 1) {		/* nested entry on this CPU */
		rg->drop++;
		return;
	}
	WRITE_ONCE(rg->head, head + 3);
	idx = (head >> 1) & rg->mask;
	rec = &rg->recs[idx];
	memset(rec, 0, sizeof(*rec));
	rec->dst = h->dst;
	rec->src = h->src;
	rec->len = h->len;
	rec->off = h->off;
	rec->q0 = h->q[0];
	rec->q1 = h->q[1];
	rec->q2 = h->q[2];
	rec->q3 = h->q[3];
	rec->lr = h->lr;
	asm volatile("mrs %0, cntvct_el0" : "=r"(ts));
	rec->ts = ts;
	rec->pid = current->pid;
	rec->flags = h->flags;
	memcpy(rec->comm, current->comm, sizeof(rec->comm));
	fv2_unwind(h->fp, rec->trace, &ntrace);
	rg->recd++;

	/* the decisive first stack hit also keeps the whole source buffer */
	if (fulldump && h->stack && !r->dump_used) {
		u32 dlen = (u32)(h->len < FV2_DUMP_SZ ? h->len : FV2_DUMP_SZ);

		r->dump_used = 1;
		r->dump_len = h->len;
		r->dump_off = h->off;
		r->dump_dst = h->dst;
		r->dump_src = h->src;
		r->dump_lr = h->lr;
		r->dump_ts = ts;
		r->dump_pid = current->pid;
		r->dump_flags = h->flags;
		memcpy(r->dump_comm, current->comm, sizeof(r->dump_comm));
		if (copy_from_kernel_nofault(r->dump, (const void *)h->src, dlen)) {
			r->dump_used = 2;
			r->srcfault++;
		} else {
			rec->flags |= FV2_F_DUMPED;
		}
	}
	WRITE_ONCE(rg->head, (head + 3) & ~1ULL);
}

/* Scan src[0..len) on 16B strides aligned to dst.  Called from the
 * trampoline only, never from process context with locks held by us. */
static void fv2_scan(struct fv2_cpu *r, u64 dst, u64 src, u64 len,
		     u64 lr, u64 fp, int stack, int near)
{
	u8 buf[FV2_CHUNK];
	u64 o = (-dst) & 0xf;	/* record VA is 16B aligned: o = -dst (mod 16) */
	unsigned int nrec = 0;

	r->scanned++;
	if (stack)
		r->stack_hot++;
	else
		r->stack_cold++;

	/* 16..31B copies: only a 16B core can fit, no 32B window */
	if (len < 32) {
		if (o + 16 <= len &&
		    !copy_from_kernel_nofault(buf, (const void *)(src + o), 16)) {
			r->bytes += 16;
			if (fv2_core16(fv2_ld64(buf), buf))
				r->core16++;
		}
		return;
	}

	while (o + 32 <= len) {
		u32 chunk = (u32)((len - o) < FV2_CHUNK ?
				  (len - o) : FV2_CHUNK);
		u32 k;

		if (copy_from_kernel_nofault(buf, (const void *)(src + o),
					     chunk)) {
			r->srcfault++;
			break;
		}
		r->bytes += chunk;
		for (k = 0; k + 16 <= chunk; k += 16) {
			u64 q0 = fv2_ld64(buf + k);
			u64 q1, q3;
			u32 fl = 0;

			/* exploratory 16B core: checked at every 16B step,
			 * including the tail where no 32B window fits. */
			if (fv2_core16(q0, buf + k))
				r->core16++;
			if (k + 32 > chunk)
				continue;
			q1 = fv2_ld64(buf + k + 8);
			q3 = fv2_ld64(buf + k + 24);
			if (q1 | q3)
				continue;	/* two-load quick filter */
			r->quick++;
			{
				u64 q2 = fv2_ld64(buf + k + 16);
				struct fv2_hit h;

				if (fv2_family_a0b2(q0, q2, buf + k, &fl))
					r->a0b2++;
				else if (fv2_family_b0a2(q0, q2))
					r->b0a2++, fl |= FV2_F_B0A2;
				else
					continue;
				if (nrec >= FV2_MAXREC_CALL) {
					r->capped++;
					continue;
				}
				nrec++;
				h.dst = dst;
				h.src = src;
				h.len = len;
				h.off = o + k;
				h.q[0] = q0;
				h.q[1] = q1;
				h.q[2] = q2;
				h.q[3] = q3;
				h.lr = lr;
				h.fp = fp;
				h.stack = stack;
				h.near = near;
				if (stack)
					fl |= FV2_F_STACK;
				if (near) {
					fl |= FV2_F_NEAR;
					r->near_hits++;
				}
				h.flags = fl;
				fv2_ring_put(r, stack ? &r->hot : &r->cold, &h);
			}
		}
		if (chunk < FV2_CHUNK)
			break;
		o += FV2_CHUNK - 16;	/* 16B overlap covers straddling windows */
	}
}

__attribute__((used))
noinline void funnelv2_cand(u64 dst, u64 src, u64 len, u64 lr, u64 fp)
{
	struct fv2_cpu *r = &fv2_cpus[raw_smp_processor_id()];
	struct mm_struct *mm;
	unsigned long ss;
	int stack = 0, near = 0;

	/* defensive re-check (the asm filter normally guarantees this) */
	/* defensive only: the asm filter routes len outside [16,0x1000]
	 * straight to the displaced instruction without entering C, so
	 * these two checks are never taken on the live path.  The
	 * out-of-range share is bounded by calls_total - (eligible+nonuser). */
	if (len < 16 || len > FV2_SCAN_MAX)
		return;
	if (dst >= FV2_USER_MAX || len > FV2_USER_MAX - dst) {
		r->nonuser++;
		return;
	}
	r->eligible++;

	mm = current->mm;
	if (mm) {
		ss = READ_ONCE(mm->start_stack);
		if (ss > FV2_STACK_WIDE &&
		    dst >= (u64)ss - FV2_STACK_WIDE &&
		    dst < (u64)ss + 0x1000) {
			stack = 1;
			if (dst >= (u64)ss - FV2_STACK_NEAR)
				near = 1;
		}
	}

	/* non-stack large copies are sampled 1:16 to bound the cost */
	if (!stack && len > 0x100 && (r->sample_tick++ & 15)) {
		r->sampled++;
		return;
	}

	fv2_scan(r, dst, src, len, lr, fp, stack, near);
}

/* ------------------------------------------------------------------ */
/* page-table walk: kernel VA -> physical address (handles PMD leaf)   */
/* ------------------------------------------------------------------ */
static int fv2_get_kernel_pgd(pgd_t **out)
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

static int fv2_walk_pa(unsigned long va, unsigned long *pa_out)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
	pmd_t pmd_v;
	pud_t pud_v;
	pte_t pte_v;

	if (fv2_get_kernel_pgd(&pgd))
		return -ENODEV;
	pgd = pgd + pgd_index(va);
	if (pgd_none(READ_ONCE(*pgd)) || pgd_bad(READ_ONCE(*pgd)))
		return -ENOENT;
	p4d = p4d_offset(pgd, va);
	if (p4d_none(READ_ONCE(*p4d)) || p4d_bad(READ_ONCE(*p4d)))
		return -ENOENT;
	pud = pud_offset(p4d, va);
	pud_v = READ_ONCE(*pud);
	if (pud_none(pud_v) || pud_bad(pud_v))
		return -ENOENT;
	if (pud_leaf(pud_v)) {
		*pa_out = ((unsigned long)__pud_to_phys(pud_v) & PUD_MASK) |
			  (va & (PUD_SIZE - 1));
		return 0;
	}
	pmd = pmd_offset(pud, va);
	pmd_v = READ_ONCE(*pmd);
	if (pmd_none(pmd_v))
		return -ENOENT;
	if (pmd_leaf(pmd_v)) {
		*pa_out = ((unsigned long)__pmd_to_phys(pmd_v) & PMD_MASK) |
			  (va & (PMD_SIZE - 1));
		return 0;
	}
	pte = pte_offset_kernel(pmd, va);
	pte_v = READ_ONCE(*pte);
	if (!pte_present(pte_v))
		return -ENOENT;
	*pa_out = ((unsigned long)__pte_to_phys(pte_v) & PAGE_MASK) |
		  (va & ~PAGE_MASK);
	return 0;
}

/* ------------------------------------------------------------------ */
/* patch primitive: write through the vmap alias + I-cache maintenance */
/* ------------------------------------------------------------------ */
struct fv2_patch_req {
	void *alias;		/* writable alias base */
	unsigned long off;	/* offset within page */
	unsigned long va;	/* image VA for icache maintenance */
	u32 insn;
};

static atomic_t fv2_patch_cpus;

static int fv2_patch_cb(void *arg)
{
	struct fv2_patch_req *r = arg;

	if (atomic_inc_return(&fv2_patch_cpus) == 1) {
		WRITE_ONCE(*(u32 *)((char *)r->alias + r->off), r->insn);
		dsb(ish);
		atomic_inc(&fv2_patch_cpus);
	} else {
		while (atomic_read(&fv2_patch_cpus) <= num_online_cpus())
			cpu_relax();
	}
	/* clean+invalidate the D line (dirtied through the alias) and the
	 * I line for the image VA on every CPU */
	asm volatile("dc	civac, %0\n"
		     "dsb	ish\n"
		     "ic	ivau, %0\n"
		     "dsb	ish\n"
		     "isb" :: "r"(r->va) : "memory");
	return 0;
}

static int fv2_write_site(u32 insn)
{
	struct fv2_patch_req req = {
		.alias = fv2_alias,
		.off = fv2_alias_off,
		.va = fv2_site,
		.insn = insn,
	};

	atomic_set(&fv2_patch_cpus, 0);
	return stop_machine(fv2_patch_cb, &req, NULL);
}

static u32 fv2_mkb(s64 delta)
{
	return 0x14000000u | (((u64)delta >> 2) & 0x03ffffffu);
}

static unsigned long fv2_b_target(unsigned long site, u32 insn)
{
	s64 d = (s64)(insn & 0x03ffffffu);

	if (d & 0x02000000)
		d -= 0x04000000;
	return (unsigned long)((s64)site + d * 4);
}

/* ------------------------------------------------------------------ */
/* verification                                                        */
/* ------------------------------------------------------------------ */
static int fv2_verify(void)
{
	unsigned long tramp = (unsigned long)funnelv2_tramp;
	s64 delta = (s64)tramp - (s64)fv2_site;
	u32 w0, w1;
	struct page *pg;
	int rc;

	w0 = READ_ONCE(*(u32 *)fv2_site);
	w1 = READ_ONCE(*(u32 *)(fv2_site + 4));
	sprint_symbol(fv2_sym, fv2_site);
	pr_info("funnelv2: site=%016lx word=%08x next=%08x sym=%s\n",
		fv2_site, w0, w1, fv2_sym);
	if (w0 != FV2_ORIG_WORD) {
		pr_err("funnelv2: site word %08x != expected %08x\n",
		       w0, FV2_ORIG_WORD);
		return -EINVAL;
	}
	pr_info("funnelv2: tramp=%016lx delta=%lld (%s)\n",
		tramp, (long long)delta,
		(delta >= -(1LL << 27) && delta < (1LL << 27)) ?
		"in-range" : "OUT-OF-RANGE");
	if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
		pr_err("funnelv2: B imm26 out of range\n");
		return -ERANGE;
	}
	rc = fv2_walk_pa(fv2_site, &fv2_pa);
	if (rc) {
		pr_err("funnelv2: page-table walk failed: %d\n", rc);
		return rc;
	}
	pr_info("funnelv2: pa=%016lx off=%03lx\n", fv2_pa, fv2_pa & ~PAGE_MASK);
	pg = pfn_to_page(fv2_pa >> PAGE_SHIFT);
	fv2_alias = vmap(&pg, 1, VM_MAP, PAGE_KERNEL);
	if (!fv2_alias) {
		pr_err("funnelv2: vmap failed\n");
		return -ENOMEM;
	}
	fv2_vmapped = true;
	fv2_alias_off = fv2_pa & ~PAGE_MASK;
	if (READ_ONCE(*(u32 *)((char *)fv2_alias + fv2_alias_off)) != w0) {
		pr_err("funnelv2: alias readback %08x != site %08x\n",
		       READ_ONCE(*(u32 *)((char *)fv2_alias + fv2_alias_off)), w0);
		return -EIO;
	}
	pr_info("funnelv2: alias=%px readback ok\n", fv2_alias);
	fv2_orig = w0;
	fv2_patch = fv2_mkb(delta);
	if (fv2_b_target(fv2_site, fv2_patch) != tramp) {
		pr_err("funnelv2: branch self-check failed\n");
		return -EINVAL;
	}
	funnelv2_ret = fv2_site + 4;
	pr_info("funnelv2: patch=%08x (b %016lx)\n", fv2_patch, tramp);
	return 0;
}

/* ------------------------------------------------------------------ */
/* install / restore                                                   */
/* ------------------------------------------------------------------ */
static int fv2_install(void)
{
	u32 cur;
	int rc;

	rc = fv2_write_site(fv2_patch);
	if (rc) {
		pr_err("funnelv2: patch stop_machine failed: %d\n", rc);
		return rc;
	}
	cur = READ_ONCE(*(u32 *)fv2_site);
	if (cur != fv2_patch) {
		pr_err("funnelv2: site readback %08x != %08x\n", cur, fv2_patch);
		return -EIO;
	}
	if (READ_ONCE(*(u32 *)((char *)fv2_alias + fv2_alias_off)) != fv2_patch) {
		pr_err("funnelv2: alias readback after patch mismatch\n");
		return -EIO;
	}
	fv2_installed = true;
	pr_info("funnelv2: INSTALLED site=%016lx -> b %016lx (word %08x)\n",
		fv2_site, (unsigned long)funnelv2_tramp, fv2_patch);
	return 0;
}

static int fv2_restore(void)
{
	u32 cur;
	int i, rc;

	if (!fv2_installed)
		return 0;
	for (i = 0; i < 3; i++) {
		rc = fv2_write_site(fv2_orig);
		if (rc) {
			pr_err("funnelv2: restore stop_machine failed: %d\n", rc);
			continue;
		}
		cur = READ_ONCE(*(u32 *)fv2_site);
		if (cur == fv2_orig)
			break;
		pr_warn("funnelv2: restore readback %08x != %08x (attempt %d)\n",
			cur, fv2_orig, i + 1);
	}
	if (i == 3 && cur != fv2_orig) {
		pr_err("funnelv2: RESTORE FAILED\n");
		return -EIO;
	}
	fv2_installed = false;
	pr_info("funnelv2: restored site word %08x (readback ok)\n", cur);
	return 0;
}

/* ------------------------------------------------------------------ */
/* /proc/funnelv2                                                      */
/* ------------------------------------------------------------------ */
static struct proc_dir_entry *fv2_pe;

static void fv2_show_ring(struct seq_file *m, const char *tag,
			  struct fv2_ring *rg, unsigned int k)
{
	u64 head = READ_ONCE(rg->head);
	u64 cnt = head >> 1;
	unsigned int show;
	unsigned int j;

	/* a writer that set the guard is still filling recs[cnt-1]; do not
	 * expose a torn in-progress record */
	if (head & 1)
		cnt = cnt ? cnt - 1 : 0;
	show = cnt < k ? (unsigned int)cnt : k;

	for (j = 0; j < show; j++) {
		u64 seq = cnt - 1 - j;
		struct fv2_rec *rec = &rg->recs[seq & rg->mask];
		u64 ts = READ_ONCE(rec->ts);
		u64 lr = READ_ONCE(rec->lr);
		u64 dst = READ_ONCE(rec->dst);
		u64 src = READ_ONCE(rec->src);
		u64 len = READ_ONCE(rec->len);
		u64 off = READ_ONCE(rec->off);
		u32 pid = READ_ONCE(rec->pid);
		u32 fl = READ_ONCE(rec->flags);
		char sym[FV2_NM] = "?";
		char comm[17];

		sprint_symbol(sym, lr);
		memcpy(comm, rec->comm, 16);
		comm[16] = 0;
		seq_printf(m,
			   "  %s#%llu ts=%llu len=%llu off=%llu dst=%016llx doff=%03llx src=%016llx lr=%016llx pid=%u fl=%04x comm=%s lr_sym=%s tr0=%016llx tr1=%016llx tr2=%016llx q0=%016llx q1=%016llx q2=%016llx q3=%016llx\n",
			   tag, seq, ts, len, off, dst, dst & 0xfffULL, src,
			   lr, pid, fl, comm, sym,
			   READ_ONCE(rec->trace[0]), READ_ONCE(rec->trace[1]),
			   READ_ONCE(rec->trace[2]),
			   READ_ONCE(rec->q0), READ_ONCE(rec->q1),
			   READ_ONCE(rec->q2), READ_ONCE(rec->q3));
	}
}

static void fv2_show_dump(struct seq_file *m, struct fv2_cpu *r)
{
	unsigned int i, len;

	if (r->dump_used != 1)
		return;
	len = (unsigned int)(r->dump_len < FV2_DUMP_SZ ?
			     r->dump_len : FV2_DUMP_SZ);
	seq_printf(m,
		   "  dump: len=%llu off=%llu dst=%016llx src=%016llx lr=%016llx ts=%llu pid=%u fl=%04x comm=%s bytes=%u\n",
		   r->dump_len, r->dump_off, r->dump_dst, r->dump_src,
		   r->dump_lr, r->dump_ts, r->dump_pid, r->dump_flags,
		   r->dump_comm, len);
	for (i = 0; i < len; i += 16) {
		unsigned int j;

		seq_printf(m, "    %04x:", i);
		for (j = 0; j < 16 && i + j < len; j++)
			seq_printf(m, " %02x", r->dump[i + j]);
		seq_putc(m, '\n');
	}
}

static int fv2_show(struct seq_file *m, void *v)
{
	unsigned int k = (maxread <= 0) ? 32 :
			 (maxread > 256 ? 256 : maxread);
	u64 freq = 0, now = 0;
	int cpu;

	asm volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	asm volatile("mrs %0, cntvct_el0" : "=r"(now));
	seq_printf(m, "funnelv2 v2.0: %s\n",
		   fv2_installed ? "PATCHED" : (dryrun ? "dryrun" : "locate-only"));
	seq_printf(m, "site=%016lx orig=%08x cur=%08x patch=%08x tramp=%016lx\n",
		   fv2_site, fv2_orig,
		   READ_ONCE(*(u32 *)fv2_site), fv2_patch,
		   (unsigned long)funnelv2_tramp);
	seq_printf(m, "pa=%016lx off=%03lx alias=%px sym=%s\n",
		   fv2_pa, fv2_alias_off, fv2_alias, fv2_sym);
	seq_printf(m, "filter: len=[16,0x1000] stride=16 o0=(-dst)&0xf stack=[start_stack-0x800000,start_stack+0x1000) near=-0x40000\n");
	seq_printf(m, "clock: cntfrq=%llu now=%llu\n", freq, now);
	seq_printf(m, "calls_total=%llu\n", READ_ONCE(funnelv2_calls));
	for_each_online_cpu(cpu) {
		struct fv2_cpu *r = &fv2_cpus[cpu];

		seq_printf(m,
			   "cpu%d: eligible=%llu scanned=%llu bytes=%llu nonuser=%llu sampled=%llu srcfault=%llu\n",
			   cpu, READ_ONCE(r->eligible), READ_ONCE(r->scanned),
			   READ_ONCE(r->bytes), READ_ONCE(r->nonuser),
			   READ_ONCE(r->sampled), READ_ONCE(r->srcfault));
		seq_printf(m,
			   "cpu%d: quick=%llu a0b2=%llu b0a2=%llu core16=%llu capped=%llu stack_hot=%llu stack_cold=%llu near=%llu recd_hot=%llu recd_cold=%llu drop_hot=%llu drop_cold=%llu guard=%llu\n",
			   cpu, READ_ONCE(r->quick), READ_ONCE(r->a0b2),
			   READ_ONCE(r->b0a2), READ_ONCE(r->core16),
			   READ_ONCE(r->capped), READ_ONCE(r->stack_hot),
			   READ_ONCE(r->stack_cold), READ_ONCE(r->near_hits),
			   READ_ONCE(r->hot.recd), READ_ONCE(r->cold.recd),
			   READ_ONCE(r->hot.drop), READ_ONCE(r->cold.drop),
			   READ_ONCE(r->hot.head) & 1);
		fv2_show_ring(m, "H", &r->hot, k);
		fv2_show_ring(m, "C", &r->cold, k);
		fv2_show_dump(m, r);
	}
	return 0;
}

static int fv2_open(struct inode *inode, struct file *file)
{
	return single_open(file, fv2_show, NULL);
}

static const struct proc_ops fv2_pops = {
	.proc_open	= fv2_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* ------------------------------------------------------------------ */
static int __init funnelv2_init(void)
{
	int rc, cpu;

	BUILD_BUG_ON(sizeof(struct fv2_rec) != 128);
	BUILD_BUG_ON(FV2_HOT_N > 1024 || FV2_COLD_N > FV2_HOT_N);

	pr_info("funnelv2: rings %zu B/cpu (%d hot x %zu + %d cold x %zu + %d dump), possible_cpus=%d\n",
		sizeof(struct fv2_cpu), FV2_HOT_N, sizeof(struct fv2_rec),
		FV2_COLD_N, sizeof(struct fv2_rec), FV2_DUMP_SZ,
		num_possible_cpus());

	fv2_cpus = vzalloc((size_t)num_possible_cpus() * sizeof(struct fv2_cpu));
	if (!fv2_cpus)
		return -ENOMEM;
	for_each_possible_cpu(cpu) {
		struct fv2_cpu *r = &fv2_cpus[cpu];

		/* vzalloc() already zeroes the whole array */
		r->hot.recs = r->hot_recs;
		r->hot.n = FV2_HOT_N;
		r->hot.mask = FV2_HOT_MASK;
		r->cold.recs = r->cold_recs;
		r->cold.n = FV2_COLD_N;
		r->cold.mask = FV2_COLD_MASK;
	}

	rc = fv2_verify();
	if (rc)
		goto out_unmap;

	if (!dryrun) {
		rc = fv2_install();
		if (rc) {
			fv2_restore();
			goto out_unmap;
		}
		pr_info("funnelv2: live, scanning len=[16,0x1000]\n");
	} else {
		pr_info("funnelv2: DRYRUN verify complete, nothing patched\n");
	}

	fv2_pe = proc_create("funnelv2", 0444, NULL, &fv2_pops);
	if (!fv2_pe) {
		rc = -ENOMEM;
		goto out_restore;
	}
	return 0;

out_restore:
	fv2_restore();
	/* a thread stopped inside the trampoline by stop_machine resumes
	 * after the patch is restored; let it finish before the percpu
	 * rings (and, after exit, the module text) go away */
	msleep(100);
out_unmap:
	if (fv2_vmapped) {
		vunmap(fv2_alias);
		fv2_vmapped = false;
	}
	vfree(fv2_cpus);
	fv2_cpus = NULL;
	return rc;
}

static void __exit funnelv2_exit(void)
{
	fv2_restore();
	if (fv2_pe)
		proc_remove(fv2_pe);
	/* Let any thread that was parked inside the trampoline when
	 * stop_machine ran finish before the percpu rings and the module
	 * text are freed.  This sleep must come BEFORE free_percpu(): v1
	 * slept after the free, which leaves a use-after-free window for a
	 * thread resumed inside funnelv2_cand(). */
	msleep(100);
	if (fv2_vmapped) {
		vunmap(fv2_alias);
		fv2_vmapped = false;
	}
	if (fv2_cpus) {
		vfree(fv2_cpus);
		fv2_cpus = NULL;
	}
	pr_info("funnelv2: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(funnelv2_init);
module_exit(funnelv2_exit);

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
