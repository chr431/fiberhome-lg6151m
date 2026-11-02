// SPDX-License-Identifier: GPL-2.0
// funnelcatcher.ko v1.0 -- D23: capture the 32B record family at the single
// uaccess funnel __arch_copy_to_user (vmlinux .text 0xffffffc00843b680).
//
// Why: N2d proved every call-style uaccess path (160 direct bl + 416 per-TU
// clones + iov_iter copyout) funnels into __arch_copy_to_user. D20/D21
// excluded mt_wifi's 12 call sites; this is the final one-shot at the funnel.
//
// Patch primitive: vmlinux .text is PMD-mapped RO and, with
// CONFIG_RODATA_FULL_DEFAULT_ENABLED=y, mark_linear_text_alias_ro() also makes
// the linear alias RO -- so writing __va(pa) would fault. Instead we walk the
// kernel page table (TTBR1), take pmd_page_paddr()/pte_page_paddr(), and create
// a private writable alias with vmap(1 page, PAGE_KERNEL). The 4-byte branch is
// written through that alias inside stop_machine; dc civac + ic ivau run on the
// image VA on every CPU; vunmap after restore. Readback via the image VA is the
// restore assertion.
//
// Trampoline: the site's first instruction (add x5,x0,x2) is displaced. The
// trampoline counts every entry, then only for len==32 / len==16 calls a C
// shape check (copy_from_kernel_nofault, so a bad src cannot oops); hits
// (len==32 && src[8..16)==0 && src[24..32)==0, or len==16 && src[8..16)==0)
// go into a per-cpu lock-free ring. Everything else re-executes the displaced
// instruction and branches back to site+4.
//
// Safety:
//   - dryrun=1 locates, verifies bytes and the branch distance, maps the page
//     read-only and writes nothing;
//   - the vmap alias readback must equal the live site word before any patch;
//   - branch distance is checked against the AArch64 B imm26 range;
//   - install/restore run under stop_machine with per-CPU I-cache maintenance;
//   - restore is read back; 3 attempts; module exit sleeps 100 ms before the
//     code can be freed (in-flight trampoline entries finish first).
//
// Module params: site=0x... (default 0xffffffc00843b680), dryrun=1, maxread=N.
//
// See docs/SIGSEGV/05_LOG/2026-11-03-06-d23-funnel.md (prereg) and N3c.md.
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
MODULE_DESCRIPTION("funnelcatcher: __arch_copy_to_user shape catcher (D23)");
MODULE_AUTHOR("chr431");

#define FUNNEL_NREC	128
#define FUNNEL_RECSZ	128
#define FUNNEL_NM	256
#define FUNNEL_NTRACE	4

/* expected first word of __arch_copy_to_user: add x5, x0, x2 */
#define FUNNEL_ORIG_WORD	0x8b020005u
#define FUNNEL_SITE_DEFAULT	0xffffffc00843b680UL

static unsigned long funnel_site = FUNNEL_SITE_DEFAULT;
module_param_named(site, funnel_site, ulong, 0444);
MODULE_PARM_DESC(funnel_site, "__arch_copy_to_user entry VA");
static int dryrun;
module_param(dryrun, int, 0444);
MODULE_PARM_DESC(dryrun, "1 = verify only, patch nothing");
static int maxread = 64;
module_param(maxread, int, 0444);
MODULE_PARM_DESC(maxread, "records printed per cpu (default 64, cap 64)");

struct funnel_rec {
	u64 ts;		/* cntvct_el0 */
	u64 lr;		/* callers x30 at the site */
	u64 dst;	/* user destination VA */
	u64 src;	/* kernel source VA */
	u64 len;	/* copy length */
	u64 trace[FUNNEL_NTRACE];	/* fp-chain return addresses */
	u8  data[32];
	char comm[16];
	u32 pid;
	u32 flags;
};

#define FUNNEL_F_FAULT	0x01	/* src read faulted (not recorded) */
#define FUNNEL_F_16	0x02	/* len==16 family */
#define FUNNEL_F_A0B2	0x04	/* family B, A0B2 form */
#define FUNNEL_F_B0A2	0x08	/* family B, B0A2 form */

struct funnel_ring {
	struct funnel_rec recs[FUNNEL_NREC];
	u64 head;		/* (idx<<1)|guard */
	u64 cand32;		/* len==32 entries seen */
	u64 cand16;		/* len==16 entries seen */
	u64 shape32;		/* len==32 with word1==0 && word3==0 */
	u64 shape16;		/* len==16 with word1==0 */
	u64 family;		/* family-B content signature, recorded */
	u64 plain;		/* shape but not family-like */
	u64 n16rec;		/* 16B samples recorded (cap 8/cpu) */
	u64 recd;
	u64 dropped;		/* nested / guard drops */
};

static struct funnel_ring __percpu *rings;

/* total entries into the trampoline (atomic, asm-incremented) */
u64 funnel_calls;

/* site+4 target, set at init */
u64 funnel_ret __read_mostly;

/* ---- trampoline: displaced insn + inline len filter + C shape check ---- */
asm(
".pushsection .text\n"
".balign 4096\n"
".globl funnel_tramp\n"
"funnel_tramp:\n"
"	adrp	x15, funnel_calls\n"
"	ldr	x16, [x15, :lo12:funnel_calls]\n"
"	add	x16, x16, #1\n"
"	str	x16, [x15, :lo12:funnel_calls]\n"
"	cmp	x2, #32\n"
"	b.eq	1f\n"
"	cmp	x2, #16\n"
"	b.ne	9f\n"
"1:\n"
"	stp	x0, x1, [sp, #-64]!\n"
"	stp	x2, x30, [sp, #16]\n"
"	mov	x3, x30\n"
"	mov	x4, x29\n"
"	bl	funnel_cand\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x30, [sp, #16]\n"
"	add	sp, sp, #64\n"
"9:\n"
"	.inst	0x8b020005\n"		/* displaced: add x5, x0, x2 */
"	adrp	x15, funnel_ret\n"
"	ldr	x16, [x15, :lo12:funnel_ret]\n"
"	br	x16\n"
".balign 16\n"
".popsection\n"
);
extern char funnel_tramp[];

static bool funnel_installed;
static bool funnel_vmapped;
static void *funnel_alias;		/* vmap base of the site page */
static unsigned long funnel_alias_off;
static u32 funnel_orig;			/* original 4 bytes */
static u32 funnel_patch;		/* b trampoline */
static unsigned long funnel_pa;		/* site physical address */
static char funnel_sym[FUNNEL_NM];

/* ------------------------------------------------------------------ */
/* record path: only called for len==32 / len==16                      */
/* ------------------------------------------------------------------ */
static void funnel_unwind(u64 fp, u64 *trace, u32 *n)
{
	int i;

	for (i = 0; i < FUNNEL_NTRACE; i++) {
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

__attribute__((used))
noinline void funnel_cand(u64 dst, u64 src, u64 len, u64 lr, u64 fp)
{
	struct funnel_ring *r = this_cpu_ptr(rings);
	u8 data[32];
	u64 w0, w1, w2, w3, head, idx, ts;
	u32 flags = 0;
	u32 ntrace = 0;
	struct funnel_rec *rec;

	/* A faulting src cannot carry a valid record (the real copy would
	 * fault-fixup too); skip safely -- no extable exists in the
	 * trampoline, so all content reads go through nofault. */
	if (copy_from_kernel_nofault(data, (const void *)src, 32)) {
		r->dropped++;
		return;
	}
	w0 = *(u64 *)(data + 0);
	w1 = *(u64 *)(data + 8);
	w2 = *(u64 *)(data + 16);
	w3 = *(u64 *)(data + 24);

	if (len == 16) {
		r->cand16++;
		if (w1 != 0)
			return;
		r->shape16++;
		flags = FUNNEL_F_16;
		if (!w0 || r->n16rec >= 8)
			return;
		r->n16rec++;
		goto record;
	}

	r->cand32++;
	if (w1 != 0 || w3 != 0)
		return;
	r->shape32++;

	/* Family B signatures (04_FAMILIES.md 3.1):
	 *   A0B2: {u64 A small, 0, u32 len, __be32 ip, u64 0}
	 *   B0A2: {u64 B tagged, 0, u64 A' small, u64 0}
	 * The permissive shape (len==32, w1==w3==0) is satisfied by ~1e3/s
	 * of benign shell/pty/sockaddr copies, so only family-like content
	 * is recorded; every permissive shape is still counted. */
	{
		u32 l = (u32)w2;

		/* A0B2: A may be any value including 0 (C-205 natural sample
		 * was {0,0,len,ip}); the len+unicast-ip pair carries the
		 * specificity, so only that pair is required. */
		if (l >= 0x40 && l <= 0x4000 &&
		    (w2 >> 32) != 0 && data[20] >= 1 && data[20] <= 223) {
			flags = FUNNEL_F_A0B2;
		} else if ((w2 >> 32) == 0 && w2 >= 0x1000ULL &&
			   w2 <= 0x100000ULL && w0 != 0) {
			flags = FUNNEL_F_B0A2;
		} else {
			r->plain++;
			return;
		}
	}
	r->family++;
record:
	head = READ_ONCE(r->head);
	if (head & 1) {		/* nested entry on this CPU */
		r->dropped++;
		return;
	}
	WRITE_ONCE(r->head, head + 3);
	idx = (head >> 1) & (FUNNEL_NREC - 1);
	rec = &r->recs[idx];
	memset(rec, 0, sizeof(*rec));
	rec->dst = dst;
	rec->src = src;
	rec->len = len;
	rec->lr = lr;
	asm volatile("mrs %0, cntvct_el0" : "=r"(ts));
	rec->ts = ts;
	rec->pid = current->pid;
	rec->flags = flags;
	memcpy(rec->comm, current->comm, sizeof(rec->comm));
	memcpy(rec->data, data, sizeof(rec->data));
	funnel_unwind(fp, rec->trace, &ntrace);
	r->recd++;
	WRITE_ONCE(r->head, (head + 3) & ~1ULL);
}

/* ------------------------------------------------------------------ */
/* page-table walk: kernel VA -> physical address (handles PMD leaf)   */
/* ------------------------------------------------------------------ */
static int funnel_get_kernel_pgd(pgd_t **out)
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

static int funnel_walk_pa(unsigned long va, unsigned long *pa_out)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
	pmd_t pmd_v;
	pud_t pud_v;
	pte_t pte_v;

	if (funnel_get_kernel_pgd(&pgd))
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
struct funnel_patch_req {
	void *alias;		/* writable alias base */
	unsigned long off;	/* offset within page */
	unsigned long va;	/* image VA for icache maintenance */
	u32 insn;
};

static atomic_t funnel_patch_cpus;

static int funnel_patch_cb(void *arg)
{
	struct funnel_patch_req *r = arg;

	if (atomic_inc_return(&funnel_patch_cpus) == 1) {
		WRITE_ONCE(*(u32 *)((char *)r->alias + r->off), r->insn);
		dsb(ish);
		atomic_inc(&funnel_patch_cpus);
	} else {
		while (atomic_read(&funnel_patch_cpus) <= num_online_cpus())
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

static int funnel_write_site(u32 insn)
{
	struct funnel_patch_req req = {
		.alias = funnel_alias,
		.off = funnel_alias_off,
		.va = funnel_site,
		.insn = insn,
	};

	atomic_set(&funnel_patch_cpus, 0);
	return stop_machine(funnel_patch_cb, &req, NULL);
}

static u32 funnel_mkb(s64 delta)
{
	return 0x14000000u | (((u64)delta >> 2) & 0x03ffffffu);
}

static unsigned long funnel_b_target(unsigned long site, u32 insn)
{
	s64 d = (s64)(insn & 0x03ffffffu);

	if (d & 0x02000000)
		d -= 0x04000000;
	return (unsigned long)((s64)site + d * 4);
}

/* ------------------------------------------------------------------ */
/* verification                                                        */
/* ------------------------------------------------------------------ */
static int funnel_verify(void)
{
	unsigned long tramp = (unsigned long)funnel_tramp;
	s64 delta = (s64)tramp - (s64)funnel_site;
	u32 w0, w1;
	struct page *pg;
	int rc;

	w0 = READ_ONCE(*(u32 *)funnel_site);
	w1 = READ_ONCE(*(u32 *)(funnel_site + 4));
	sprint_symbol(funnel_sym, funnel_site);
	pr_info("funnelcatcher: site=%016lx word=%08x next=%08x sym=%s\n",
		funnel_site, w0, w1, funnel_sym);
	if (w0 != FUNNEL_ORIG_WORD) {
		pr_err("funnelcatcher: site word %08x != expected %08x\n",
		       w0, FUNNEL_ORIG_WORD);
		return -EINVAL;
	}
	pr_info("funnelcatcher: tramp=%016lx delta=%lld (%s)\n",
		tramp, (long long)delta,
		(delta >= -(1LL << 27) && delta < (1LL << 27)) ? "in-range" : "OUT-OF-RANGE");
	if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
		pr_err("funnelcatcher: B imm26 out of range\n");
		return -ERANGE;
	}
	rc = funnel_walk_pa(funnel_site, &funnel_pa);
	if (rc) {
		pr_err("funnelcatcher: page-table walk failed: %d\n", rc);
		return rc;
	}
	pr_info("funnelcatcher: pa=%016lx off=%03lx\n",
		funnel_pa, funnel_pa & ~PAGE_MASK);
	pg = pfn_to_page(funnel_pa >> PAGE_SHIFT);
	funnel_alias = vmap(&pg, 1, VM_MAP, PAGE_KERNEL);
	if (!funnel_alias) {
		pr_err("funnelcatcher: vmap failed\n");
		return -ENOMEM;
	}
	funnel_vmapped = true;
	funnel_alias_off = funnel_pa & ~PAGE_MASK;
	if (READ_ONCE(*(u32 *)((char *)funnel_alias + funnel_alias_off)) != w0) {
		pr_err("funnelcatcher: alias readback %08x != site %08x\n",
		       READ_ONCE(*(u32 *)((char *)funnel_alias + funnel_alias_off)), w0);
		return -EIO;
	}
	pr_info("funnelcatcher: alias=%px readback ok\n", funnel_alias);
	funnel_orig = w0;
	funnel_patch = funnel_mkb(delta);
	if (funnel_b_target(funnel_site, funnel_patch) != tramp) {
		pr_err("funnelcatcher: branch self-check failed\n");
		return -EINVAL;
	}
	funnel_ret = funnel_site + 4;
	pr_info("funnelcatcher: patch=%08x (b %016lx)\n", funnel_patch, tramp);
	return 0;
}

/* ------------------------------------------------------------------ */
/* install / restore                                                   */
/* ------------------------------------------------------------------ */
static int funnel_install(void)
{
	u32 cur;
	int rc;

	rc = funnel_write_site(funnel_patch);
	if (rc) {
		pr_err("funnelcatcher: patch stop_machine failed: %d\n", rc);
		return rc;
	}
	cur = READ_ONCE(*(u32 *)funnel_site);
	if (cur != funnel_patch) {
		pr_err("funnelcatcher: site readback %08x != %08x\n", cur, funnel_patch);
		return -EIO;
	}
	if (READ_ONCE(*(u32 *)((char *)funnel_alias + funnel_alias_off)) != funnel_patch) {
		pr_err("funnelcatcher: alias readback after patch mismatch\n");
		return -EIO;
	}
	funnel_installed = true;
	pr_info("funnelcatcher: INSTALLED site=%016lx -> b %016lx (word %08x)\n",
		funnel_site, (unsigned long)funnel_tramp, funnel_patch);
	return 0;
}

static int funnel_restore(void)
{
	u32 cur;
	int i, rc;

	if (!funnel_installed)
		return 0;
	for (i = 0; i < 3; i++) {
		rc = funnel_write_site(funnel_orig);
		if (rc) {
			pr_err("funnelcatcher: restore stop_machine failed: %d\n", rc);
			continue;
		}
		cur = READ_ONCE(*(u32 *)funnel_site);
		if (cur == funnel_orig)
			break;
		pr_warn("funnelcatcher: restore readback %08x != %08x (attempt %d)\n",
			cur, funnel_orig, i + 1);
	}
	if (i == 3 && cur != funnel_orig) {
		pr_err("funnelcatcher: RESTORE FAILED\n");
		return -EIO;
	}
	funnel_installed = false;
	pr_info("funnelcatcher: restored site word %08x (readback ok)\n", cur);
	return 0;
}

/* ------------------------------------------------------------------ */
/* /proc/funnelcatcher                                                 */
/* ------------------------------------------------------------------ */
static struct proc_dir_entry *funnel_pe;

static int funnel_show(struct seq_file *m, void *v)
{
	unsigned int k = (maxread <= 0) ? 64 : (maxread > FUNNEL_NREC ? FUNNEL_NREC : maxread);
	u64 freq = 0, now = 0;
	int cpu;

	asm volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	asm volatile("mrs %0, cntvct_el0" : "=r"(now));
	seq_printf(m, "funnelcatcher v1.0: %s\n",
		   funnel_installed ? "PATCHED" : (dryrun ? "dryrun" : "locate-only"));
	seq_printf(m, "site=%016lx orig=%08x cur=%08x patch=%08x tramp=%016lx\n",
		   funnel_site, funnel_orig,
		   READ_ONCE(*(u32 *)funnel_site), funnel_patch,
		   (unsigned long)funnel_tramp);
	seq_printf(m, "pa=%016lx off=%03lx alias=%px sym=%s\n",
		   funnel_pa, funnel_alias_off, funnel_alias, funnel_sym);
	seq_printf(m, "clock: cntfrq=%llu now=%llu\n", freq, now);
	seq_printf(m, "calls_total=%llu\n", READ_ONCE(funnel_calls));
	for_each_online_cpu(cpu) {
		struct funnel_ring *r = per_cpu_ptr(rings, cpu);
		u64 head = READ_ONCE(r->head);
		u64 cnt = head >> 1;
		unsigned int show = cnt < k ? (unsigned int)cnt : k;
		unsigned int j;

		seq_printf(m, "cpu%d: cand32=%llu shape32=%llu family=%llu plain=%llu cand16=%llu shape16=%llu recd=%llu dropped=%llu guard=%llu\n",
			   cpu, READ_ONCE(r->cand32), READ_ONCE(r->shape32),
			   READ_ONCE(r->family), READ_ONCE(r->plain),
			   READ_ONCE(r->cand16), READ_ONCE(r->shape16),
			   READ_ONCE(r->recd), READ_ONCE(r->dropped), head & 1);
		for (j = 0; j < show; j++) {
			u64 seq = cnt - 1 - j;
			struct funnel_rec *rec = &r->recs[seq & (FUNNEL_NREC - 1)];
			u64 ts = READ_ONCE(rec->ts);
			u64 lr = READ_ONCE(rec->lr);
			u64 dst = READ_ONCE(rec->dst);
			u64 src = READ_ONCE(rec->src);
			u64 len = READ_ONCE(rec->len);
			u32 pid = READ_ONCE(rec->pid);
			u32 fl = READ_ONCE(rec->flags);
			const u8 *d = rec->data;
			char sym[FUNNEL_NM] = "?";
			char comm[17];

			sprint_symbol(sym, lr);
			memcpy(comm, rec->comm, 16);
			comm[16] = 0;
			seq_printf(m,
				   "  #%llu ts=%llu len=%llu dst=%016llx src=%016llx lr=%016llx pid=%u fl=%02x comm=%s lr_sym=%s tr0=%016llx tr1=%016llx tr2=%016llx tr3=%016llx data=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x\n",
				   seq, ts, len, dst, src, lr, pid, fl, comm, sym,
				   READ_ONCE(rec->trace[0]), READ_ONCE(rec->trace[1]),
				   READ_ONCE(rec->trace[2]), READ_ONCE(rec->trace[3]),
				   d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
				   d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15],
				   d[16], d[17], d[18], d[19], d[20], d[21], d[22], d[23],
				   d[24], d[25], d[26], d[27], d[28], d[29], d[30], d[31]);
		}
	}
	return 0;
}

static int funnel_open(struct inode *inode, struct file *file)
{
	return single_open(file, funnel_show, NULL);
}

static const struct proc_ops funnel_pops = {
	.proc_open	= funnel_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* ------------------------------------------------------------------ */
static int __init funnelcatcher_init(void)
{
	int rc, cpu;

	BUILD_BUG_ON(sizeof(struct funnel_rec) != FUNNEL_RECSZ);

	rings = alloc_percpu(struct funnel_ring);
	if (!rings)
		return -ENOMEM;
	for_each_possible_cpu(cpu)
		memset(per_cpu_ptr(rings, cpu), 0, sizeof(struct funnel_ring));

	rc = funnel_verify();
	if (rc)
		goto out_unmap;

	if (!dryrun) {
		rc = funnel_install();
		if (rc) {
			funnel_restore();
			goto out_unmap;
		}
		pr_info("funnelcatcher: live, capturing\n");
	} else {
		pr_info("funnelcatcher: DRYRUN verify complete, nothing patched\n");
	}

	funnel_pe = proc_create("funnelcatcher", 0444, NULL, &funnel_pops);
	if (!funnel_pe) {
		rc = -ENOMEM;
		goto out_restore;
	}
	return 0;

out_restore:
	funnel_restore();
out_unmap:
	if (funnel_vmapped) {
		vunmap(funnel_alias);
		funnel_vmapped = false;
	}
	free_percpu(rings);
	rings = NULL;
	return rc;
}

static void __exit funnelcatcher_exit(void)
{
	funnel_restore();
	if (funnel_pe)
		proc_remove(funnel_pe);
	if (funnel_vmapped) {
		vunmap(funnel_alias);
		funnel_vmapped = false;
	}
	if (rings) {
		free_percpu(rings);
		rings = NULL;
	}
	/* let any thread that was parked inside the trampoline when
	 * stop_machine ran finish before the module text is freed */
	if (funnel_installed == false)
		msleep(100);
	pr_info("funnelcatcher: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(funnelcatcher_init);
module_exit(funnelcatcher_exit);

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
