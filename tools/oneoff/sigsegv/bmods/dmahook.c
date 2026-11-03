// SPDX-License-Identifier: GPL-2.0
// dmahook.ko v1.0 -- D24: catch DMA mappings of user anonymous pages.
//
// Why: D23 (C-206) physically excluded the CPU uaccess funnel
// (__arch_copy_to_user, 28.96M calls, zero family-B content). The only
// remaining class for the 32B record family is DMA / bus-master write:
// the host only programs a physical address into a descriptor, so the
// writer never touches copy_to_user. If the target page is a user anon
// page, the host must have dma_map'ed it first -- this module watches for
// exactly that.
//
// Sites (vmlinux .text, both paciasp-first; verified at init):
//   dma_map_page_attrs 0xffffffc00819aef0  -> covers dma_map_page/single
//   dma_map_sg_attrs   0xffffffc00819a6f4  -> covers dma_map_sg (scatter-
//                                            gather, the network/storage
//                                            data plane)
//
// Filter: PageAnon(page) == ((unsigned long)page->mapping & 1). Safety:
//   - page pointer must lie in the vmemmap window (compile-time constants
//     from asm/memory.h; re-checked at init against a freshly allocated
//     page);
//   - compound_head: bit0 only means "tail" if (head-1) is itself a
//     vmemmap-aligned struct page (page_pool's pp_magic and slab lists
//     occupy that union slot; blindly trusting bit0 would dereference a
//     wild pointer);
//   - struct page offsets pinned with BUILD_BUG_ON (mapping=24,
//     compound_head=8, size=64).
//
// Patch primitive: identical to funnelcatcher/D23 (linear alias of .text is
// RO under rodata_full): walk TTBR1 -> page PA -> pfn_to_page -> vmap one
// page writable -> write the 4-byte 'b' -> dc civac + ic ivau per CPU on
// the image VA inside stop_machine -> vunmap after restore.
//
// Trampoline: entered via a direct 'b' from the site, so SP is still the
// original entry SP. We save x0..x5/x29/x30 WITHOUT touching SP semantics
// of the displaced instruction: the filter runs first (recording the clean,
// unsigned x30), then SP is restored and the displaced paciasp is executed
// exactly where the original code would have run it (same SP modifier), and
// finally we branch to site+4. The function's own autiasp therefore still
// verifies.
//
// Positive control: "echo 1 > /proc/dmahook" runs an internal selftest:
// one real struct device captured from live DMA traffic, one freshly
// allocated page temporarily marked PageAnon, mapped once through
// dma_map_page_attrs and once through dma_map_sg_attrs, then unmapped and
// released. Expected: exactly one PAGE + one SG anon hit, lr resolving to
// this module.
//
// Module params: dryrun=1 (locate/verify only, patch nothing), maxread=N.
//
// See docs/SIGSEGV/05_LOG/2026-11-03-07-d24-dmamap.md (prereg) and
// _local/investigations/sigsegv-tools/phase-AB/D1.md.
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
#include <linux/scatterlist.h>
#include <linux/dma-mapping.h>
#include <asm/pgtable.h>
#include <asm/memory.h>
#include <asm/processor.h>
#include <asm/barrier.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dmahook: PageAnon dma_map catcher (D24)");
MODULE_AUTHOR("chr431");

#define D24_NREC	128
#define D24_RECSZ	192
#define D24_NM		512	/* >= KSYM_SYMBOL_LEN (sprint_symbol has no length arg) */
#define D24_NTRACE	4
#define D24_SAMPLE_MAX	8
#define D24_SG_SCAN_MAX	32

#define D24_ORIG_WORD	0xd503233fu	/* paciasp */
#define D24_SITE_PAGE	0xffffffc00819aef0UL
#define D24_SITE_SG	0xffffffc00819a6f4UL
#define D24_SITE_P0B	0xffffffc00855fa88UL
#define D24_SITE_P1_DEFAULT	0UL	/* fmac_write_txp: live module addr via param */
#define D24_DEV_DMA_MASK_OFF	0x238UL	/* dev->dma_mask, E3 from the
					 * vmlinux disassembly of the site */

struct dmahook_rec {
	u64 ts;		/* cntvct_el0 */
	u64 lr;		/* caller x30 at the site (unsigned) */
	u64 page;	/* struct page * (as mapped) */
	u64 head;	/* compound head used for the anon test */
	u64 pfn;
	u64 phys;	/* page_to_phys(page) */
	u64 offset;
	u64 size;
	u64 dir;
	u64 attrs;
	u64 dev;
	u64 mapping;	/* head->mapping raw value */
	u64 trace[D24_NTRACE];
	u32 pid;
	u32 flags;
	u32 refcount;
	u32 mapcount;
	u32 sgi;	/* sg index, PAGE records: 0 */
	u32 nents;
	char comm[16];
	u8 pad[24];
};

#define D24_F_PAGE	0x01
#define D24_F_SG	0x02
#define D24_F_ANON	0x04
#define D24_F_SAMPLE	0x08
#define D24_F_FAKE	0x10	/* page outside vmemmap: user-VA-derived */
#define D24_F_USERVA	0x20	/* P0b: x0 < TASK_SIZE at entry */

struct dmahook_ring {
	struct dmahook_rec recs[D24_NREC];
	u64 head;
	u64 calls_page;
	u64 calls_sg;
	u64 sg_entries;
	u64 pbad;	/* page pointer outside vmemmap (now: fake) */
	u64 fake;	/* fake-page records */
	u64 calls_p0b;
	u64 p0bhits;
	u64 calls_p1;
	u64 p1hits;
	u64 anon;
	u64 recd;
	u64 dropped;
	u64 samples;
	u64 last_dev;
};

static struct dmahook_ring __percpu *rings;

/* total entries into the two trampolines (approximate, per-cpu) */
u64 dmahook_calls_page;
u64 dmahook_calls_sg;

/* site+4 targets, set at init */
u64 dmahook_ret_page __read_mostly;
u64 dmahook_ret_sg __read_mostly;
u64 dmahook_ret_p0b __read_mostly;
u64 dmahook_ret_p1 __read_mostly;

/* ---- trampolines: filter first, displaced paciasp last ---- */
asm(
".pushsection .text\n"
".balign 4096\n"
".globl dmahook_tramp_page\n"
"dmahook_tramp_page:\n"
"	stp	x0, x1, [sp, #-96]!\n"
"	stp	x2, x3, [sp, #16]\n"
"	stp	x4, x5, [sp, #32]\n"
"	stp	x29, x30, [sp, #48]\n"
"	mov	x6, x30\n"
"	mov	x7, x29\n"
"	bl	dmahook_page\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x3, [sp, #16]\n"
"	ldp	x4, x5, [sp, #32]\n"
"	ldp	x29, x30, [sp, #48]\n"
"	add	sp, sp, #96\n"
"	.inst	0xd503233f\n"		/* displaced: paciasp */
"	adrp	x15, dmahook_ret_page\n"
"	ldr	x16, [x15, :lo12:dmahook_ret_page]\n"
"	br	x16\n"
".balign 16\n"
".popsection\n"
);

asm(
".pushsection .text\n"
".balign 4096\n"
".globl dmahook_tramp_sg\n"
"dmahook_tramp_sg:\n"
"	stp	x0, x1, [sp, #-96]!\n"
"	stp	x2, x3, [sp, #16]\n"
"	stp	x4, x5, [sp, #32]\n"
"	stp	x29, x30, [sp, #48]\n"
"	mov	x6, x30\n"
"	mov	x7, x29\n"
"	bl	dmahook_sg\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x3, [sp, #16]\n"
"	ldp	x4, x5, [sp, #32]\n"
"	ldp	x29, x30, [sp, #48]\n"
"	add	sp, sp, #96\n"
"	.inst	0xd503233f\n"		/* displaced: paciasp */
"	adrp	x15, dmahook_ret_sg\n"
"	ldr	x16, [x15, :lo12:dmahook_ret_sg]\n"
"	br	x16\n"
".balign 16\n"
".popsection\n"
);

extern char dmahook_tramp_page[];
extern char dmahook_tramp_sg[];
extern char dmahook_tramp_p0b[];
extern char dmahook_tramp_p1[];

asm(
".pushsection .text\n"
".balign 4096\n"
".globl dmahook_tramp_p0b\n"
"dmahook_tramp_p0b:\n"
"	stp	x0, x1, [sp, #-96]!\n"
"	stp	x2, x3, [sp, #16]\n"
"	stp	x4, x5, [sp, #32]\n"
"	stp	x29, x30, [sp, #48]\n"
"	mov	x6, x30\n"
"	mov	x7, x29\n"
"	bl	dmahook_p0b\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x3, [sp, #16]\n"
"	ldp	x4, x5, [sp, #32]\n"
"	ldp	x29, x30, [sp, #48]\n"
"	add	sp, sp, #96\n"
"	.inst	0xd503233f\n"		/* displaced: paciasp */
"	adrp	x15, dmahook_ret_p0b\n"
"	ldr	x16, [x15, :lo12:dmahook_ret_p0b]\n"
"	br	x16\n"
".balign 16\n"
".popsection\n"
);

asm(
".pushsection .text\n"
".balign 4096\n"
".globl dmahook_tramp_p1\n"
"dmahook_tramp_p1:\n"
"	stp	x0, x1, [sp, #-96]!\n"
"	stp	x2, x3, [sp, #16]\n"
"	stp	x4, x5, [sp, #32]\n"
"	stp	x29, x30, [sp, #48]\n"
"	mov	x6, x30\n"
"	mov	x7, x29\n"
"	bl	dmahook_p1\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x3, [sp, #16]\n"
"	ldp	x4, x5, [sp, #32]\n"
"	ldp	x29, x30, [sp, #48]\n"
"	add	sp, sp, #96\n"
"	.inst	0xd503233f\n"		/* displaced: paciasp */
"	adrp	x15, dmahook_ret_p1\n"
"	ldr	x16, [x15, :lo12:dmahook_ret_p1]\n"
"	br	x16\n"
".balign 16\n"
".popsection\n"
);

struct dmahook_site {
	unsigned long va;
	u32 orig;
	u32 patch;
	unsigned long pa;
	unsigned long alias_off;
	void *alias;
	unsigned long tramp;
	bool vmapped;
	bool installed;
	char sym[D24_NM];
	const char *name;
};

static struct dmahook_site sites[4] = {
	{ .va = D24_SITE_PAGE, .orig = D24_ORIG_WORD,
	  .name = "dma_map_page_attrs" },
	{ .va = D24_SITE_SG, .orig = D24_ORIG_WORD,
	  .name = "dma_map_sg_attrs" },
	{ .va = D24_SITE_P0B, .orig = D24_ORIG_WORD,
	  .name = "dpmaif_alloc_med_rx_frag" },
	{ .va = D24_SITE_P1_DEFAULT, .orig = D24_ORIG_WORD,
	  .name = "fmac_write_txp" },
};
#define D24_NSITES	ARRAY_SIZE(sites)

static unsigned long p1_site;
module_param(p1_site, ulong, 0444);
MODULE_PARM_DESC(p1_site, "fmac_write_txp live VA (0 = skip P1)");
static int dryrun;
module_param(dryrun, int, 0444);
MODULE_PARM_DESC(dryrun, "1 = verify only, patch nothing");
static int maxread = 64;
module_param(maxread, int, 0444);
MODULE_PARM_DESC(maxread, "records printed per cpu (default 64, cap 128)");

/* ------------------------------------------------------------------ */
/* struct page helpers                                                 */
/* ------------------------------------------------------------------ */
static inline int dmahook_pvalid(struct page *p)
{
	unsigned long a = (unsigned long)p;

	return a >= VMEMMAP_START && a < VMEMMAP_END &&
	       (a & (__alignof__(struct page) - 1)) == 0;
}

static inline struct page *dmahook_head(struct page *p)
{
	unsigned long ch = READ_ONCE(p->compound_head);

	if (ch & 1UL) {
		unsigned long h = ch - 1;

		/* only a real tail page: the candidate head must be a
		 * vmemmap-aligned struct page. page_pool pp_magic (0x...bcd)
		 * and slab list pointers must not be dereferenced. */
		if (h >= VMEMMAP_START && h < VMEMMAP_END &&
		    (h & (__alignof__(struct page) - 1)) == 0)
			return (struct page *)h;
	}
	return p;
}

static inline int dmahook_is_anon(struct page *p, struct page **head)
{
	struct page *h = dmahook_head(p);
	unsigned long m;

	*head = h;
	m = (unsigned long)READ_ONCE(h->mapping);
	return (m & 1UL) != 0;
}

static void dmahook_unwind(u64 fp, u64 *trace, u32 *n)
{
	int i;

	for (i = 0; i < D24_NTRACE; i++) {
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

/* record into the per-cpu ring; caller holds nothing (lock-free guard) */
static void dmahook_record(struct dmahook_ring *r, struct dmahook_rec *src)
{
	u64 head = READ_ONCE(r->head);
	u64 idx;
	struct dmahook_rec *rec;

	if (head & 1) {
		r->dropped++;
		return;
	}
	WRITE_ONCE(r->head, head + 3);
	idx = (head >> 1) & (D24_NREC - 1);
	rec = &r->recs[idx];
	*rec = *src;
	r->recd++;
	WRITE_ONCE(r->head, (head + 3) & ~1ULL);
}

/* ------------------------------------------------------------------ */
/* filter: dma_map_page_attrs(dev, page, offset, size, dir, attrs)     */
/* ------------------------------------------------------------------ */
__attribute__((used))
noinline void dmahook_page(u64 dev, u64 page, u64 offset, u64 size,
			   u64 dir, u64 attrs, u64 lr, u64 fp)
{
	struct dmahook_ring *r = this_cpu_ptr(rings);
	struct page *p = (struct page *)page;
	struct page *head;
	struct dmahook_rec rec;
	u32 ntrace = 0;
	int anon;

	r->calls_page++;
	WRITE_ONCE(r->last_dev, dev);
	if (!dmahook_pvalid(p)) {
		/* D2 family: user VA was fed to virt_to_page, producing a
		 * pointer outside vmemmap (user VA in [0,2^39) provably maps
		 * to [0,2^33)). Record without dereferencing. */
		r->pbad++;
		r->fake++;
		memset(&rec, 0, sizeof(rec));
		asm volatile("mrs %0, cntvct_el0" : "=r"(rec.ts));
		rec.lr = lr;
		rec.page = page;
		rec.offset = offset;
		rec.size = size;
		rec.dir = dir;
		rec.attrs = attrs;
		rec.dev = dev;
		rec.pid = current->pid;
		rec.flags = D24_F_PAGE | D24_F_FAKE;
		memcpy(rec.comm, current->comm, sizeof(rec.comm));
		dmahook_unwind(fp, rec.trace, &ntrace);
		dmahook_record(r, &rec);
		return;
	}
	anon = dmahook_is_anon(p, &head);
	if (!anon) {
		if (r->samples >= D24_SAMPLE_MAX)
			return;
		r->samples++;
	} else {
		r->anon++;
	}

	memset(&rec, 0, sizeof(rec));
	rec.ts = 0;
	asm volatile("mrs %0, cntvct_el0" : "=r"(rec.ts));
	rec.lr = lr;
	rec.page = page;
	rec.head = (u64)head;
	rec.pfn = page_to_pfn(p);
	rec.phys = page_to_phys(p);
	rec.offset = offset;
	rec.size = size;
	rec.dir = dir;
	rec.attrs = attrs;
	rec.dev = dev;
	rec.mapping = (u64)READ_ONCE(head->mapping);
	rec.refcount = (u32)page_ref_count(head);
	rec.mapcount = (u32)atomic_read(&head->_mapcount);
	rec.pid = current->pid;
	rec.flags = D24_F_PAGE | (anon ? D24_F_ANON : D24_F_SAMPLE);
	memcpy(rec.comm, current->comm, sizeof(rec.comm));
	dmahook_unwind(fp, rec.trace, &ntrace);
	dmahook_record(r, &rec);
}

/* ------------------------------------------------------------------ */
/* filter: dma_map_sg_attrs(dev, sg, nents, dir, attrs)                */
/* ------------------------------------------------------------------ */
__attribute__((used))
noinline void dmahook_sg(u64 dev, u64 sgp, u64 nents, u64 dir, u64 attrs,
			 u64 pad, u64 lr, u64 fp)
{
	struct dmahook_ring *r = this_cpu_ptr(rings);
	u64 n, i;

	r->calls_sg++;
	WRITE_ONCE(r->last_dev, dev);
	if (!sgp || !nents || dir > 2)
		return;
	n = nents < D24_SG_SCAN_MAX ? nents : D24_SG_SCAN_MAX;
	for (i = 0; i < n; i++) {
		struct scatterlist *s = (struct scatterlist *)(sgp +
					i * sizeof(struct scatterlist));
		unsigned long pl = READ_ONCE(s->page_link);
		struct page *p;
		struct page *head;
		struct dmahook_rec rec;
		u32 ntrace = 0;

		if (pl & 1UL)		/* chained sg */
			break;
		p = (struct page *)(pl & ~3UL);
		r->sg_entries++;
		if (!dmahook_pvalid(p)) {
			r->pbad++;
			if (pl & 2UL)
				break;
			continue;
		}
		if (!dmahook_is_anon(p, &head)) {
			if (pl & 2UL)
				break;
			continue;
		}
		r->anon++;
		memset(&rec, 0, sizeof(rec));
		asm volatile("mrs %0, cntvct_el0" : "=r"(rec.ts));
		rec.lr = lr;
		rec.page = (u64)p;
		rec.head = (u64)head;
		rec.pfn = page_to_pfn(p);
		rec.phys = page_to_phys(p);
		rec.offset = READ_ONCE(s->offset);
		rec.size = READ_ONCE(s->length);
		rec.dir = dir;
		rec.attrs = attrs;
		rec.dev = dev;
		rec.mapping = (u64)READ_ONCE(head->mapping);
		rec.refcount = (u32)page_ref_count(head);
		rec.mapcount = (u32)atomic_read(&head->_mapcount);
		rec.sgi = (u32)i;
		rec.nents = (u32)nents;
		rec.pid = current->pid;
		rec.flags = D24_F_SG | D24_F_ANON;
		memcpy(rec.comm, current->comm, sizeof(rec.comm));
		dmahook_unwind(fp, rec.trace, &ntrace);
		dmahook_record(r, &rec);
		if (pl & 2UL)
			break;
	}
}

/* ------------------------------------------------------------------ */
/* P0b: dpmaif_alloc_med_rx_frag entry, x0 < TASK_SIZE => user VA      */
/* ------------------------------------------------------------------ */
__attribute__((used))
noinline void dmahook_p0b(u64 va, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5,
			  u64 lr, u64 fp)
{
	struct dmahook_ring *r = this_cpu_ptr(rings);
	struct dmahook_rec rec;
	u32 ntrace = 0;

	r->calls_p0b++;
	if (va >= (1UL << VA_BITS))
		return;		/* normal case: x0 is a kernel struct pointer */
	r->p0bhits++;
	memset(&rec, 0, sizeof(rec));
	asm volatile("mrs %0, cntvct_el0" : "=r"(rec.ts));
	rec.lr = lr;
	rec.page = va;		/* the user VA seen in x0 */
	rec.pid = current->pid;
	rec.flags = D24_F_FAKE | D24_F_USERVA | D24_F_PAGE;
	memcpy(rec.comm, current->comm, sizeof(rec.comm));
	dmahook_unwind(fp, rec.trace, &ntrace);
	dmahook_record(r, &rec);
}

/* ------------------------------------------------------------------ */
/* P1: mtk_hwifi:fmac_write_txp entry -- cached VA at [x1+0x10]+0xc8   */
/* ------------------------------------------------------------------ */
__attribute__((used))
noinline void dmahook_p1(u64 a0, u64 txp, u64 a2, u64 a3, u64 a4, u64 a5,
			 u64 lr, u64 fp)
{
	struct dmahook_ring *r = this_cpu_ptr(rings);
	struct dmahook_rec rec;
	u64 obj, va;
	u32 ntrace = 0;

	r->calls_p1++;
	if (txp < 0xffff000000000000ULL || (txp & 7))
		return;
	obj = *(u64 *)(txp + 0x10);
	if (obj < 0xffff000000000000ULL || (obj & 7))
		return;
	va = *(u64 *)(obj + 0xc8);
	if (!va || (va & PAGE_OFFSET))
		return;		/* kernel VA: normal */
	r->p1hits++;
	memset(&rec, 0, sizeof(rec));
	asm volatile("mrs %0, cntvct_el0" : "=r"(rec.ts));
	rec.lr = lr;
	rec.page = va;		/* cached VA from the resident struct */
	rec.dev = txp;		/* txp pointer */
	rec.pid = current->pid;
	rec.flags = D24_F_PAGE | D24_F_FAKE | D24_F_USERVA;
	memcpy(rec.comm, current->comm, sizeof(rec.comm));
	dmahook_unwind(fp, rec.trace, &ntrace);
	dmahook_record(r, &rec);
}

/* ------------------------------------------------------------------ */
/* page-table walk: kernel VA -> physical address (handles PMD leaf)   */
/* ------------------------------------------------------------------ */
static int dmahook_get_kernel_pgd(pgd_t **out)
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

static int dmahook_walk_pa(unsigned long va, unsigned long *pa_out)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
	pmd_t pmd_v;
	pud_t pud_v;
	pte_t pte_v;

	if (dmahook_get_kernel_pgd(&pgd))
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
/* patch primitive                                                     */
/* ------------------------------------------------------------------ */
struct dmahook_patch_req {
	void *alias;
	unsigned long off;
	unsigned long va;
	u32 insn;
};

static atomic_t dmahook_patch_cpus;

static int dmahook_patch_cb(void *arg)
{
	struct dmahook_patch_req *r = arg;

	if (atomic_inc_return(&dmahook_patch_cpus) == 1) {
		WRITE_ONCE(*(u32 *)((char *)r->alias + r->off), r->insn);
		dsb(ish);
		atomic_inc(&dmahook_patch_cpus);
	} else {
		while (atomic_read(&dmahook_patch_cpus) <= num_online_cpus())
			cpu_relax();
	}
	asm volatile("dc	civac, %0\n"
		     "dsb	ish\n"
		     "ic	ivau, %0\n"
		     "dsb	ish\n"
		     "isb" :: "r"(r->va) : "memory");
	return 0;
}

static int dmahook_write_site(struct dmahook_site *s, u32 insn)
{
	struct dmahook_patch_req req = {
		.alias = s->alias,
		.off = s->alias_off,
		.va = s->va,
		.insn = insn,
	};

	atomic_set(&dmahook_patch_cpus, 0);
	return stop_machine(dmahook_patch_cb, &req, NULL);
}

static u32 dmahook_mkb(s64 delta)
{
	return 0x14000000u | (((u64)delta >> 2) & 0x03ffffffu);
}

static unsigned long dmahook_b_target(unsigned long site, u32 insn)
{
	s64 d = (s64)(insn & 0x03ffffffu);

	if (d & 0x02000000)
		d -= 0x04000000;
	return (unsigned long)((s64)site + d * 4);
}

/* ------------------------------------------------------------------ */
/* verification                                                        */
/* ------------------------------------------------------------------ */
static int dmahook_verify_site(struct dmahook_site *s)
{
	s64 delta = (s64)s->tramp - (s64)s->va;
	u32 w0, w1;
	struct page *pg;
	int rc;

	w0 = READ_ONCE(*(u32 *)s->va);
	w1 = READ_ONCE(*(u32 *)(s->va + 4));
	sprint_symbol(s->sym, s->va);
	pr_info("dmahook: %s site=%016lx word=%08x next=%08x sym=%s\n",
		s->name, s->va, w0, w1, s->sym);
	if (w0 != s->orig) {
		pr_err("dmahook: %s word %08x != expected %08x\n",
		       s->name, w0, s->orig);
		return -EINVAL;
	}
	pr_info("dmahook: %s tramp=%016lx delta=%lld (%s)\n", s->name,
		s->tramp, (long long)delta,
		(delta >= -(1LL << 27) && delta < (1LL << 27)) ?
		"in-range" : "OUT-OF-RANGE");
	if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
		pr_err("dmahook: %s B imm26 out of range\n", s->name);
		return -ERANGE;
	}
	rc = dmahook_walk_pa(s->va, &s->pa);
	if (rc) {
		pr_err("dmahook: %s page-table walk failed: %d\n", s->name, rc);
		return rc;
	}
	pg = pfn_to_page(s->pa >> PAGE_SHIFT);
	s->alias = vmap(&pg, 1, VM_MAP, PAGE_KERNEL);
	if (!s->alias) {
		pr_err("dmahook: %s vmap failed\n", s->name);
		return -ENOMEM;
	}
	s->vmapped = true;
	s->alias_off = s->pa & ~PAGE_MASK;
	if (READ_ONCE(*(u32 *)((char *)s->alias + s->alias_off)) != w0) {
		pr_err("dmahook: %s alias readback != site\n", s->name);
		return -EIO;
	}
	pr_info("dmahook: %s pa=%016lx off=%03lx alias=%px readback ok\n",
		s->name, s->pa, s->alias_off, s->alias);
	s->patch = dmahook_mkb(delta);
	if (dmahook_b_target(s->va, s->patch) != s->tramp) {
		pr_err("dmahook: %s branch self-check failed\n", s->name);
		return -EINVAL;
	}
	pr_info("dmahook: %s patch=%08x (b %016lx)\n", s->name, s->patch,
		s->tramp);
	return 0;
}

static int dmahook_verify(void)
{
	unsigned int i;
	int rc;

	for (i = 0; i < D24_NSITES; i++) {
		if (!sites[i].va)
			continue;	/* P1 not configured this run */
		rc = dmahook_verify_site(&sites[i]);
		if (rc)
			return rc;
	}
	dmahook_ret_page = D24_SITE_PAGE + 4;
	dmahook_ret_sg = D24_SITE_SG + 4;
	dmahook_ret_p0b = D24_SITE_P0B + 4;
	if (sites[3].va)
		dmahook_ret_p1 = sites[3].va + 4;
	return 0;
}

/* ------------------------------------------------------------------ */
/* install / restore                                                   */
/* ------------------------------------------------------------------ */
static int dmahook_install(void)
{
	unsigned int i;
	int rc;

	for (i = 0; i < D24_NSITES; i++) {
		struct dmahook_site *s = &sites[i];
		u32 cur;

		if (!s->va)
			continue;
		rc = dmahook_write_site(s, s->patch);
		if (rc) {
			pr_err("dmahook: %s patch stop_machine failed: %d\n",
			       s->name, rc);
			return rc;
		}
		cur = READ_ONCE(*(u32 *)s->va);
		if (cur != s->patch) {
			pr_err("dmahook: %s site readback %08x != %08x\n",
			       s->name, cur, s->patch);
			return -EIO;
		}
		if (READ_ONCE(*(u32 *)((char *)s->alias + s->alias_off)) !=
		    s->patch) {
			pr_err("dmahook: %s alias readback after patch\n",
			       s->name);
			return -EIO;
		}
		s->installed = true;
		pr_info("dmahook: INSTALLED %s %016lx -> b %016lx (word %08x)\n",
			s->name, s->va, s->tramp, s->patch);
	}
	return 0;
}

static int dmahook_restore(void)
{
	unsigned int i;
	int rc, bad = 0;

	for (i = 0; i < D24_NSITES; i++) {
		struct dmahook_site *s = &sites[i];
		u32 cur = 0;
		int k;

		if (!s->installed)
			continue;
		for (k = 0; k < 3; k++) {
			rc = dmahook_write_site(s, s->orig);
			if (rc) {
				pr_err("dmahook: %s restore stop_machine %d\n",
				       s->name, rc);
				continue;
			}
			cur = READ_ONCE(*(u32 *)s->va);
			if (cur == s->orig)
				break;
			pr_warn("dmahook: %s restore readback %08x (attempt %d)\n",
				s->name, cur, k + 1);
		}
		if (cur != s->orig) {
			pr_err("dmahook: %s RESTORE FAILED\n", s->name);
			bad++;
			continue;
		}
		s->installed = false;
		pr_info("dmahook: restored %s word %08x (readback ok)\n",
			s->name, cur);
	}
	return bad ? -EIO : 0;
}

/* ------------------------------------------------------------------ */
/* positive control                                                    */
/* ------------------------------------------------------------------ */
static int dmahook_selftest(void)
{
	struct device *dev = NULL;
	struct page *page;
	struct scatterlist sg;
	unsigned long saved_ch, saved_map;
	dma_addr_t addr;
	int i, rc = 0;
	unsigned long long pphys;

	for_each_online_cpu(i) {
		struct dmahook_ring *r = per_cpu_ptr(rings, i);
		u64 d = READ_ONCE(r->last_dev);

		if (d && *(void **)((char *)d + D24_DEV_DMA_MASK_OFF)) {
			dev = (struct device *)d;
			break;
		}
	}
	if (!dev) {
		pr_err("dmahook: selftest: no live device captured yet\n");
		return -ENODEV;
	}
	page = alloc_pages(GFP_KERNEL, 0);
	if (!page)
		return -ENOMEM;
	pphys = (unsigned long long)page_to_phys(page);
	saved_ch = READ_ONCE(page->compound_head);
	saved_map = (unsigned long)READ_ONCE(page->mapping);
	WRITE_ONCE(page->compound_head, 0);
	WRITE_ONCE(page->mapping, (struct address_space *)1UL);

	addr = dma_map_page_attrs(dev, page, 0, 32, DMA_TO_DEVICE, 0);
	if (addr == DMA_MAPPING_ERROR) {
		pr_err("dmahook: selftest: dma_map_page_attrs failed\n");
		rc = -EIO;
	} else {
		dma_unmap_page_attrs(dev, addr, 32, DMA_TO_DEVICE, 0);
	}

	sg_init_table(&sg, 1);
	sg_set_page(&sg, page, 32, 0);
	if (dma_map_sg_attrs(dev, &sg, 1, DMA_TO_DEVICE, 0) == 0) {
		pr_err("dmahook: selftest: dma_map_sg_attrs failed\n");
		rc = -EIO;
	} else {
		dma_unmap_sg_attrs(dev, &sg, 1, DMA_TO_DEVICE, 0);
	}

	WRITE_ONCE(page->mapping, (struct address_space *)saved_map);
	WRITE_ONCE(page->compound_head, saved_ch);
	__free_pages(page, 0);
	pr_info("dmahook: selftest done rc=%d dev=%px phys=%llx\n", rc, dev,
		pphys);
	return rc;
}

/* ------------------------------------------------------------------ */
/* /proc/dmahook                                                       */
/* ------------------------------------------------------------------ */
static struct proc_dir_entry *dmahook_pe;

static int dmahook_show(struct seq_file *m, void *v)
{
	unsigned int k = (maxread <= 0) ? 64 :
			 (maxread > D24_NREC ? D24_NREC : maxread);
	u64 freq = 0, now = 0, calls_page = 0, calls_sg = 0, anon = 0,
	    recd = 0, pbad = 0, sgent = 0, dropped = 0, samples = 0;
	u64 fake = 0, p0bc = 0, p0bh = 0, p1c = 0, p1h = 0;
	unsigned int i;
	int cpu;

	asm volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	asm volatile("mrs %0, cntvct_el0" : "=r"(now));
	seq_printf(m, "dmahook v1.0: %s\n",
		   (sites[0].installed && sites[1].installed) ? "PATCHED" :
		   (dryrun ? "dryrun" : "locate-only"));
	for (i = 0; i < D24_NSITES; i++) {
		struct dmahook_site *s = &sites[i];

		if (!s->va)
			continue;
		seq_printf(m,
			   "site[%u]=%016lx %s orig=%08x cur=%08x patch=%08x tramp=%016lx\n",
			   i, s->va, s->name, s->orig,
			   READ_ONCE(*(u32 *)s->va), s->patch, s->tramp);
		seq_printf(m, "  pa=%016lx off=%03lx alias=%px sym=%s\n",
			   s->pa, s->alias_off, s->alias, s->sym);
	}
	seq_printf(m, "vmemmap=[%016lx,%016lx) sizeof_page=%zu mapping_off=%zu head_off=%zu\n",
		   (unsigned long)VMEMMAP_START, (unsigned long)VMEMMAP_END,
		   sizeof(struct page), offsetof(struct page, mapping),
		   offsetof(struct page, compound_head));
	seq_printf(m, "clock: cntfrq=%llu now=%llu\n", freq, now);
	for_each_online_cpu(cpu) {
		struct dmahook_ring *r = per_cpu_ptr(rings, cpu);
		u64 head = READ_ONCE(r->head);
		u64 cnt = head >> 1;
		unsigned int show = cnt < k ? (unsigned int)cnt : k;
		unsigned int j;

		calls_page += READ_ONCE(r->calls_page);
		calls_sg += READ_ONCE(r->calls_sg);
		anon += READ_ONCE(r->anon);
		recd += READ_ONCE(r->recd);
		pbad += READ_ONCE(r->pbad);
		sgent += READ_ONCE(r->sg_entries);
		dropped += READ_ONCE(r->dropped);
		samples += READ_ONCE(r->samples);
		fake += READ_ONCE(r->fake);
		p0bc += READ_ONCE(r->calls_p0b);
		p0bh += READ_ONCE(r->p0bhits);
		p1c += READ_ONCE(r->calls_p1);
		p1h += READ_ONCE(r->p1hits);
		seq_printf(m,
			   "cpu%d: calls_page=%llu calls_sg=%llu sg_entries=%llu anon=%llu fake=%llu samples=%llu pbad=%llu recd=%llu dropped=%llu p0bcalls=%llu p0bhits=%llu p1calls=%llu p1hits=%llu guard=%llu last_dev=%016llx\n",
			   cpu, READ_ONCE(r->calls_page), READ_ONCE(r->calls_sg),
			   READ_ONCE(r->sg_entries), READ_ONCE(r->anon),
			   READ_ONCE(r->fake), READ_ONCE(r->samples), READ_ONCE(r->pbad),
			   READ_ONCE(r->recd), READ_ONCE(r->dropped),
			   READ_ONCE(r->calls_p0b), READ_ONCE(r->p0bhits),
			   READ_ONCE(r->calls_p1), READ_ONCE(r->p1hits),
			   head & 1, READ_ONCE(r->last_dev));
		for (j = 0; j < show; j++) {
			u64 seq = cnt - 1 - j;
			struct dmahook_rec *rec =
				&r->recs[seq & (D24_NREC - 1)];
			u64 ts = READ_ONCE(rec->ts);
			u64 lr = READ_ONCE(rec->lr);
			u32 pid = READ_ONCE(rec->pid);
			u32 fl = READ_ONCE(rec->flags);
			char comm[17];

			memcpy(comm, rec->comm, 16);
			comm[16] = 0;
			seq_printf(m,
				   "  #%llu ts=%llu lr=%016llx pid=%u fl=%02x comm=%s page=%016llx head=%016llx pfn=%llu phys=%016llx off=%llu size=%llu dir=%llu attrs=%llx dev=%016llx map=%016llx rc=%u mc=%d sgi=%u nents=%u tr0=%016llx tr1=%016llx tr2=%016llx tr3=%016llx\n",
				   seq, ts, lr, pid, fl, comm,
				   READ_ONCE(rec->page), READ_ONCE(rec->head),
				   READ_ONCE(rec->pfn), READ_ONCE(rec->phys),
				   READ_ONCE(rec->offset), READ_ONCE(rec->size),
				   READ_ONCE(rec->dir), READ_ONCE(rec->attrs),
				   READ_ONCE(rec->dev), READ_ONCE(rec->mapping),
				   READ_ONCE(rec->refcount),
				   (int)READ_ONCE(rec->mapcount),
				   READ_ONCE(rec->sgi), READ_ONCE(rec->nents),
				   READ_ONCE(rec->trace[0]),
				   READ_ONCE(rec->trace[1]),
				   READ_ONCE(rec->trace[2]),
				   READ_ONCE(rec->trace[3]));
		}
	}
	seq_printf(m,
		   "TOTAL: calls_page=%llu calls_sg=%llu sg_entries=%llu anon=%llu fake=%llu samples=%llu pbad=%llu recd=%llu dropped=%llu p0bcalls=%llu p0bhits=%llu p1calls=%llu p1hits=%llu\n",
		   calls_page, calls_sg, sgent, anon, fake, samples, pbad, recd,
		   dropped, p0bc, p0bh, p1c, p1h);
	return 0;
}

static int dmahook_open(struct inode *inode, struct file *file)
{
	return single_open(file, dmahook_show, NULL);
}

static ssize_t dmahook_proc_write(struct file *file, const char __user *ubuf,
				  size_t len, loff_t *off)
{
	char buf[8];
	int rc;

	if (len > sizeof(buf) - 1)
		len = sizeof(buf) - 1;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = 0;
	if (buf[0] != '1')
		return len;
	rc = dmahook_selftest();
	pr_info("dmahook: selftest trigger rc=%d\n", rc);
	return len;
}

static const struct proc_ops dmahook_pops = {
	.proc_open	= dmahook_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
	.proc_write	= dmahook_proc_write,
};

/* ------------------------------------------------------------------ */
static int __init dmahook_init(void)
{
	struct page *probe;
	int rc, cpu;
	unsigned long paddr;

	BUILD_BUG_ON(sizeof(struct dmahook_rec) != D24_RECSZ);
	BUILD_BUG_ON(offsetof(struct page, compound_head) != 8);
	BUILD_BUG_ON(offsetof(struct page, mapping) != 24);
	BUILD_BUG_ON(offsetof(struct page, _refcount) != 52);
	BUILD_BUG_ON(offsetof(struct page, _mapcount) != 48);
	BUILD_BUG_ON(sizeof(struct page) != 64);

	rings = alloc_percpu(struct dmahook_ring);
	if (!rings)
		return -ENOMEM;
	for_each_possible_cpu(cpu)
		memset(per_cpu_ptr(rings, cpu), 0, sizeof(struct dmahook_ring));

	/* runtime layout self-check: a page we own must be in vmemmap */
	probe = alloc_pages(GFP_KERNEL, 0);
	if (!probe) {
		rc = -ENOMEM;
		goto out_rings;
	}
	paddr = page_to_phys(probe);
	pr_info("dmahook: probe page=%px phys=%016lx valid=%d vmemmap=[%016lx,%016lx) pgsz=%zu mapoff=%zu headoff=%zu\n",
		probe, paddr, dmahook_pvalid(probe),
		(unsigned long)VMEMMAP_START, (unsigned long)VMEMMAP_END,
		sizeof(struct page), offsetof(struct page, mapping),
		offsetof(struct page, compound_head));
	if (!dmahook_pvalid(probe)) {
		pr_err("dmahook: probe page outside compile-time vmemmap window\n");
		__free_pages(probe, 0);
		rc = -ERANGE;
		goto out_rings;
	}
	__free_pages(probe, 0);

	/* fake-page predicate self-check (pure arithmetic, no dma_map):
	 * a user VA fed to virt_to_page lands at vmemmap + ((va+2^39)>>12)<<6,
	 * which must be classified as outside vmemmap (D2 family). */
	{
		unsigned long uv = 0x7fd103d400UL;
		unsigned long fp = (unsigned long)VMEMMAP_START +
			(((uv + (1UL << 39)) >> 12) << 6);

		pr_info("dmahook: fake-pred selfcheck va=%016lx -> page=%016lx valid=%d (expect 0)\n",
			uv, fp, dmahook_pvalid((struct page *)fp));
		if (dmahook_pvalid((struct page *)fp)) {
			pr_err("dmahook: fake predicate FAILED\n");
			rc = -EINVAL;
			goto out_rings;
		}
	}

	sites[0].tramp = (unsigned long)dmahook_tramp_page;
	sites[1].tramp = (unsigned long)dmahook_tramp_sg;
	sites[2].tramp = (unsigned long)dmahook_tramp_p0b;
	if (p1_site) {
		sites[3].va = p1_site;
		sites[3].tramp = (unsigned long)dmahook_tramp_p1;
	}

	rc = dmahook_verify();
	if (rc)
		goto out_unmap;

	if (!dryrun) {
		rc = dmahook_install();
		if (rc) {
			dmahook_restore();
			goto out_unmap;
		}
		pr_info("dmahook: live, capturing\n");
	} else {
		pr_info("dmahook: DRYRUN verify complete, nothing patched\n");
	}

	dmahook_pe = proc_create("dmahook", 0644, NULL, &dmahook_pops);
	if (!dmahook_pe) {
		rc = -ENOMEM;
		goto out_restore;
	}
	return 0;

out_restore:
	dmahook_restore();
out_unmap:
	for (cpu = 0; cpu < D24_NSITES; cpu++) {
		if (sites[cpu].vmapped) {
			vunmap(sites[cpu].alias);
			sites[cpu].vmapped = false;
		}
	}
out_rings:
	free_percpu(rings);
	rings = NULL;
	return rc;
}

static void __exit dmahook_exit(void)
{
	unsigned int i;

	dmahook_restore();
	if (dmahook_pe)
		proc_remove(dmahook_pe);
	for (i = 0; i < D24_NSITES; i++) {
		if (sites[i].vmapped) {
			vunmap(sites[i].alias);
			sites[i].vmapped = false;
		}
	}
	if (rings) {
		free_percpu(rings);
		rings = NULL;
	}
	/* let in-flight trampoline entries finish before our text is freed */
	msleep(100);
	pr_info("dmahook: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(dmahook_init);
module_exit(dmahook_exit);

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
