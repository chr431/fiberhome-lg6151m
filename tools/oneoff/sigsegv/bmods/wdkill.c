// SPDX-License-Identifier: GPL-2.0
// wdkill.ko v1.0 -- ATTRIBUTION kill-switch for mt_wifi's copy_to_user family.
//
// Source analysis: _local/investigations/sigsegv-tools/phase-AB/N2b-uaccess-sites.md
//   N2b found 12 __arch_copy_to_user sites in mt_wifi.ko:
//     7 wrapper clones (168 static callers) + 5 inline expansions.
//   Every wrapper caller fetches dst from a per-adapter resident descriptor
//   ({buf@+0x10, out_len@+0x18}) before the copy.  The hypothesis under test:
//   the 32B {A,0,{len,ip},0} records are written by this uaccess family.
//
// ================== why this is NOT N2b's "mov x0,xzr" patch ==================
// N2b §7.0 proposed replacing each clone's access_ok `csel x0,x5,xzr,eq`
// (0x9a9f00a0) with `mov x0,xzr` (0xaa1f03e0) so every copy targets NULL.
// That is FATAL on this kernel:
//   CONFIG_HARDENED_USERCOPY=y  and  CONFIG_PANIC_ON_OOPS=y   (both verified
//   against the device IKCONFIG dump tmpfiles/an4/config.gz, byte-identical to
//   the build tree's .config).
// Each wrapper calls __check_object_size(dst, len, true) BEFORE the copy
// (e.g. W1: bl @0x25bc8).  With dst == NULL, check_bogus_address() ->
// ZERO_OR_NULL_PTR(0) -> usercopy_abort("null address") -> BUG() ->
// panic_on_oops -> immediate reboot (mm/usercopy.c:99,155-156).  The very first
// ioctl would reboot the box, not silence the writer.
//
// The kill-switch is therefore implemented one instruction later, at the
// `bl __arch_copy_to_user` call itself:
//
//     wdkill_stub:
//         mov x0, x2          ; copy_to_user contract: return bytes NOT copied
//         ret                 ; back to the instruction after the bl
//
// Replacing `bl __arch_copy_to_user` with `bl wdkill_stub` makes every one of
// the 168 wrapper callers take the "all bytes failed" path:
//   - no user memory is written (no sttr is ever issued),
//   - no fault, no usercopy check, no BUG,
//   - the ioctl handler returns -EFAULT exactly as for a genuine bad pointer.
// This is a strictly stronger kill than N2b's: it removes the copy instead of
// redirecting it, and it cannot trip the hardened-usercopy abort.
//
// ===================== what is validated before any write =====================
// The .text offsets come from N2b's snapshot of mt_wifi.ko (13,551,208 B).
// A different vendor build can move them, so the module re-verifies a
// 4/5-word fingerprint at every site before patching a single byte:
//
//   W1..W6:  [bl-0x10] csel x0,x5,xzr,eq  = 0x9a9f00a0   (N2b's csel table)
//            [bl-0x0c] csdb              = 0xd503229f
//            [bl-0x08] mov x2,x4         = 0xaa0403e2
//            [bl-0x04] mov x1,x6         = 0xaa0603e1
//            [bl     ] bl <target>       (opcode 0b100101)
//   W7    :  [bl-0x0c] csel x0,x4,xzr,eq  = 0x9a9f0080
//            [bl-0x08] csdb              = 0xd503229f
//            [bl-0x04] mov x1,x5         = 0xaa0503e1
//            [bl     ] bl <target>
//
// Any mismatch refuses the load with -EINVAL and prints the actual words.
// dryrun=1 always loads and reports, even when a site fails, so the operator
// can read the actual bytes from /proc/wdkill.
//
// ===================== module base resolution =====================
// kallsyms_lookup_name is not exported (5.7+) and CONFIG_KPROBES=n, so the base
// is found by walking the kernel's module list from our own struct module:
// THIS_MODULE->list is linked into the global `modules` list by load_module()
// before our init runs.  `list` (offset 8) and `name` (offset 24) are the first
// members of struct module and are config-independent; core_layout follows
// config-dependent fields, and the device .config is byte-identical to the
// build tree's (verified), so the offset matches.  Every result is still
// cross-checked:
//   1. mod->core_layout.base page aligned and inside [MODULES_VADDR,MODULES_END)
//   2. sprint_symbol(base + 0x25bac) must contain "[mt_wifi]"
//   3. all 7 site fingerprints must match (the real gate)
// A second, layout-independent locator scans the module region page by page
// for the first 32 bytes of mt_wifi's .text and cross-checks the result.
//
// ===================== text writing =====================
// Same proven primitive as tuphook.ko (on-device validated): read TTBR1_EL1 to
// get the kernel pgd, walk pgd->p4d->pud->pmd->pte, flip the single module
// text PTE writable, write the words with all CPUs parked in stop_machine,
// run dc cvau + ic ivau on every CPU, restore the PTE.  pmd_leaf is refused.
// One writable window per distinct 4K page (the 7 sites live on 7 pages).
//
// Module params:
//   dryrun=1   locate + validate + report only; not one byte is written
//
// rmmod restores the original `bl` words (saved at install), verifies the
// readback, and drops the reference taken on mt_wifi.
//
// See REVIEW-wdkill.md for the per-function audit, the crash-path analysis and
// the on-device load/unload sequence.
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
#include <linux/sched/task.h>
#include <linux/pid.h>
#include <linux/atomic.h>
#include <linux/stop_machine.h>
#include <linux/cpumask.h>
#include <linux/smp.h>
#include <linux/delay.h>
#include <linux/string.h>
#include <linux/stdarg.h>
#include <linux/kallsyms.h>
#include <linux/types.h>
#include <linux/list.h>
#include <asm/pgtable.h>
#include <asm/memory.h>
#include <asm/barrier.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("wdkill: attribution kill-switch for mt_wifi copy_to_user wrappers (v1.0)");
MODULE_AUTHOR("chr431");

/* ---- mt_wifi.ko .text offsets (N2b snapshot; re-verified at load) ---- */
#define WD_SITE_N		7
#define WD_TEXT_SIG_LEN		32
#define WD_NM			256

/* instruction words */
#define WD_INS_CSEL_W1		0x9a9f00a0u	/* csel x0,x5,xzr,eq */
#define WD_INS_CSEL_W7		0x9a9f0080u	/* csel x0,x4,xzr,eq */
#define WD_INS_CSDB		0xd503229fu
#define WD_INS_MOV_X2_X4	0xaa0403e2u	/* mov x2,x4 */
#define WD_INS_MOV_X1_X6	0xaa0603e1u	/* mov x1,x6 */
#define WD_INS_MOV_X1_X5	0xaa0503e1u	/* mov x1,x5 (W7) */

/* the stub: mov x0,x2 ; ret */
#define WD_INS_MOV_X0_X2	0xaa0203e0u
#define WD_INS_RET		0xd65f03c0u

struct wd_exp {
	s16 delta;	/* relative to the bl site */
	u32 word;
};

struct wd_site {
	const char *name;
	u32 csel_off;		/* .text offset of the access_ok csel (report only) */
	u32 csel_want;
	u32 bl_off;		/* .text offset of `bl __arch_copy_to_user` */
	int nexp;
	struct wd_exp exp[4];
};

static const struct wd_site wd_sites[WD_SITE_N] = {
	{ "W1 RTMPAPQueryInformation x90 + others (100 callers)",
	  0x25be4, WD_INS_CSEL_W1, 0x25bf4, 4,
	  { { -0x10, WD_INS_CSEL_W1 }, { -0x0c, WD_INS_CSDB },
	    { -0x08, WD_INS_MOV_X2_X4 }, { -0x04, WD_INS_MOV_X1_X6 } } },
	{ "W2 ap_assoc_extra_ie/KeyEvent/PmkCacheEvent (3)",
	  0x13c350, WD_INS_CSEL_W1, 0x13c360, 4,
	  { { -0x10, WD_INS_CSEL_W1 }, { -0x0c, WD_INS_CSDB },
	    { -0x08, WD_INS_MOV_X2_X4 }, { -0x04, WD_INS_MOV_X1_X6 } } },
	{ "W3 rt28xx_ap_ioctl (1)",
	  0x1eac34, WD_INS_CSEL_W1, 0x1eac44, 4,
	  { { -0x10, WD_INS_CSEL_W1 }, { -0x0c, WD_INS_CSDB },
	    { -0x08, WD_INS_MOV_X2_X4 }, { -0x04, WD_INS_MOV_X1_X6 } } },
	{ "W4 rt28xx_sta_ioctl (2)",
	  0x1f576c, WD_INS_CSEL_W1, 0x1f577c, 4,
	  { { -0x10, WD_INS_CSEL_W1 }, { -0x0c, WD_INS_CSDB },
	    { -0x08, WD_INS_MOV_X2_X4 }, { -0x04, WD_INS_MOV_X1_X6 } } },
	{ "W5 RTMPQueryInformation x54 + RTMPIoctlE2PROM (55)",
	  0x237420, WD_INS_CSEL_W1, 0x237430, 4,
	  { { -0x10, WD_INS_CSEL_W1 }, { -0x0c, WD_INS_CSDB },
	    { -0x08, WD_INS_MOV_X2_X4 }, { -0x04, WD_INS_MOV_X1_X6 } } },
	{ "W6 site survey/MAC/RxStat (5)",
	  0x2b4728, WD_INS_CSEL_W1, 0x2b4738, 4,
	  { { -0x10, WD_INS_CSEL_W1 }, { -0x0c, WD_INS_CSDB },
	    { -0x08, WD_INS_MOV_X2_X4 }, { -0x04, WD_INS_MOV_X1_X6 } } },
	{ "W7 rd_* radar debug proc (7, leaf clone)",
	  0x2dc1f8, WD_INS_CSEL_W7, 0x2dc204, 3,
	  { { -0x0c, WD_INS_CSEL_W7 }, { -0x08, WD_INS_CSDB },
	    { -0x04, WD_INS_MOV_X1_X5 }, { 0, 0 } } },
};

static int dryrun;
module_param(dryrun, int, 0444);
MODULE_PARM_DESC(dryrun, "1 = locate + validate + report only, patch nothing");

/* ---- the kill stub (our own .text, executable, never freed) ---- */
asm(
".pushsection .text\n"
".balign 4096\n"
".globl wdkill_stub\n"
"wdkill_stub:\n"
"	mov	x0, x2\n"
"	ret\n"
".balign 16\n"
".globl wdkill_stub_end\n"
"wdkill_stub_end:\n"
".popsection\n"
);
extern char wdkill_stub[];

/* ---- state ---- */
static bool installed;
static unsigned long g_base;
static u32 g_orig[WD_SITE_N];	/* original bl words saved at install */
static u32 g_patched[WD_SITE_N];	/* words we wrote */
static char g_report[6144];
static int g_note;		/* report cursor */
static struct proc_dir_entry *wd_pe;
static struct module *g_mtwifi;
static const char *g_method = "none";
static int g_located;
static int g_valid;		/* all sites matched */

static void wd_rep(const char *fmt, ...)
{
	va_list ap;
	int n;

	if (g_note >= (int)sizeof(g_report) - 2)
		return;
	va_start(ap, fmt);
	n = vsnprintf(g_report + g_note, sizeof(g_report) - (size_t)g_note, fmt, ap);
	va_end(ap);
	if (n > 0)
		g_note += n;
	if (g_note > (int)sizeof(g_report) - 1)
		g_note = sizeof(g_report) - 1;
}

static int wd_rd32(unsigned long addr, u32 *v)
{
	return copy_from_kernel_nofault(v, (const void *)addr, 4);
}

/* ------------------------------------------------------------------ */
/* module base resolution                                              */
/* ------------------------------------------------------------------ */
static int wd_find_mt_wifi(struct module **out)
{
	struct module *self = THIS_MODULE;
	struct list_head *head = &self->list;
	struct list_head *pos;
	int guard = 0;

	pos = READ_ONCE(head->next);
	while (pos && pos != head && guard++ < 1024) {
		struct module *m = container_of(pos, struct module, list);
		char name[MODULE_NAME_LEN];

		memset(name, 0, sizeof(name));
		if (!copy_from_kernel_nofault(name, m->name, sizeof(name)) &&
		    !strncmp(name, "mt_wifi", sizeof(name))) {
			*out = m;
			return 0;
		}
		pos = READ_ONCE(pos->next);
	}
	return -ENOENT;
}

/* Layout-independent locator: mt_wifi's .text starts at a page boundary and
 * begins with a 32-byte sequence that has no page-aligned duplicate in the
 * shipped .ko.  Only used as a cross-check / fallback. */
static const u8 wd_text_sig[WD_TEXT_SIG_LEN] = {
	0x02, 0x48, 0x43, 0x91, 0x00, 0x48, 0x43, 0x91, 0x21, 0x1c, 0x00, 0x12,
	0x00, 0x4c, 0x33, 0x91, 0x3f, 0x23, 0x03, 0xd5, 0x43, 0x48, 0x73, 0x39,
	0x02, 0x00, 0x80, 0xd2, 0x7f, 0x00, 0x22, 0x6b,
};

static unsigned long wd_scan_text(void)
{
	unsigned long va;
	u8 buf[WD_TEXT_SIG_LEN];
	int hits = 0;
	unsigned long found = 0;

	for (va = MODULES_VADDR; va < MODULES_END; va += PAGE_SIZE) {
		if (copy_from_kernel_nofault(buf, (const void *)va,
					     sizeof(buf)))
			continue;
		if (!memcmp(buf, wd_text_sig, sizeof(buf))) {
			hits++;
			found = va;
		}
	}
	if (hits != 1)
		return 0;
	return found;
}

static void wd_sym(unsigned long addr, char *buf, size_t n)
{
	buf[0] = '\0';
	sprint_symbol(buf, addr);
}

/* Validate one site against the expected fingerprint.  Returns 0 on match,
 * -EINVAL otherwise; the actual words are appended to the report either way. */
static int wd_check_site(int i, unsigned long base)
{
	const struct wd_site *s = &wd_sites[i];
	u32 got;
	int k, ok = 1;

	for (k = 0; k < s->nexp; k++) {
		unsigned long a = base + s->bl_off + s->exp[k].delta;

		if (wd_rd32(a, &got)) {
			wd_rep("  %-52s @%#08x %+#06x  UNREADABLE\n",
			       s->name, s->bl_off, s->exp[k].delta);
			ok = 0;
			continue;
		}
		if (got != s->exp[k].word) {
			wd_rep("  %-52s @%#08x %+#06x  got %08x want %08x  MISMATCH\n",
			       s->name, s->bl_off, s->exp[k].delta, got,
			       s->exp[k].word);
			ok = 0;
		} else {
			wd_rep("  %-52s @%#08x %+#06x  got %08x want %08x  ok\n",
			       s->name, s->bl_off, s->exp[k].delta, got,
			       s->exp[k].word);
		}
	}
	/* the patch site itself must decode as a BL */
	if (wd_rd32(base + s->bl_off, &got) || (got & 0xfc000000u) != 0x94000000u) {
		wd_rep("  %-52s @%#08x          got %08x want BL opcode  MISMATCH\n",
		       s->name, s->bl_off, got);
		ok = 0;
	} else {
		unsigned long tgt;
		s64 d = (s64)(got & 0x03ffffffu);
		char nm[WD_NM];

		if (d & 0x02000000)
			d -= 0x04000000;
		tgt = (unsigned long)((s64)(base + s->bl_off) + d * 4);
		wd_sym(tgt, nm, sizeof(nm));
		wd_rep("  %-52s @%#08x          bl -> %016lx %s\n",
		       s->name, s->bl_off, tgt, nm);
	}
	return ok ? 0 : -EINVAL;
}

static int wd_locate(void)
{
	struct module *m = NULL;
	unsigned long base = 0, scan;
	char nm[WD_NM];
	int rc;

	wd_rep("wdkill v1.0: locate\n");
	rc = wd_find_mt_wifi(&m);
	if (!rc && !try_module_get(m)) {
		wd_rep("module-list: mt_wifi found but refcount get failed\n");
		rc = -ENOENT;
		m = NULL;
	}
	if (!rc) {
		g_mtwifi = m;		/* pinned: mt_wifi cannot vanish under us */
		base = (unsigned long)m->core_layout.base;
		g_method = "module-list";
		wd_rep("module-list: struct module @%px name=mt_wifi base=%016lx size=%#x text=%#x\n",
		       m, base, m->core_layout.size, m->core_layout.text_size);
	} else {
		wd_rep("module-list: mt_wifi not found (%d)\n", rc);
	}

	scan = wd_scan_text();
	wd_rep("scan: .text signature %s%016lx\n",
	       scan ? "found at " : "NOT FOUND ", scan);

	if (!base && scan) {
		base = scan;
		g_method = "scan";
	}
	if (base && scan && base != scan) {
		wd_rep("REFUSING: module-list base %016lx != scan base %016lx\n",
		       base, scan);
		return -EINVAL;
	}
	if (!base) {
		wd_rep("REFUSING: no mt_wifi base\n");
		return -ENOENT;
	}
	if (base & (PAGE_SIZE - 1)) {
		wd_rep("REFUSING: base %016lx not page aligned\n", base);
		return -EINVAL;
	}
	if (base < MODULES_VADDR || base >= MODULES_END) {
		wd_rep("REFUSING: base %016lx outside [%lx,%lx)\n", base,
		       (unsigned long)MODULES_VADDR, (unsigned long)MODULES_END);
		return -EINVAL;
	}
	wd_sym(base + wd_sites[0].csel_off, nm, sizeof(nm));
	wd_rep("sprint_symbol(base+%#x) = %s\n", wd_sites[0].csel_off, nm);
	if (!strstr(nm, "[mt_wifi]")) {
		wd_rep("REFUSING: base+%#x does not resolve into mt_wifi\n",
		       wd_sites[0].csel_off);
		return -EINVAL;
	}
	g_base = base;
	g_located = 1;
	return 0;
}

static int wd_validate(void)
{
	int i, bad = 0;

	wd_rep("fingerprints (7 clones):\n");
	for (i = 0; i < WD_SITE_N; i++) {
		if (wd_check_site(i, g_base))
			bad++;
	}
	if (bad) {
		wd_rep("VALIDATION FAILED: %d/%d sites mismatch\n", bad,
		       WD_SITE_N);
		return -EINVAL;
	}
	wd_rep("VALIDATION OK: 7/7 clones match the N2b snapshot\n");
	g_valid = 1;
	return 0;
}

/* ------------------------------------------------------------------ */
/* page-table window for writing module text (tuphook-proven)          */
/* ------------------------------------------------------------------ */
struct pte_flip {
	pte_t *ptep;
	pte_t val;
	unsigned long page;
};

static int wd_get_kernel_pgd(pgd_t **out)
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

static int wd_walk_pte(unsigned long va, pte_t **out)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;

	if (wd_get_kernel_pgd(&pgd))
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

static int wd_flip_cb(void *arg)
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

static int wd_set_pte(pte_t *ptep, pte_t val, unsigned long page)
{
	struct pte_flip f = {
		.ptep = ptep,
		.val = val,
		.page = page,
	};

	atomic_set(&flip_cpus, 0);
	return stop_machine(wd_flip_cb, &f, NULL);
}

struct wd_item {
	void *addr;
	u32 insn;
};

struct wd_req {
	struct wd_item items[8];
	int n;
};

static atomic_t patch_cpus;

static int wd_patch_cb(void *arg)
{
	struct wd_req *r = arg;
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

/* patch up to 8 words on one page; leaves the PTE exactly as found */
static int wd_patch_words(unsigned long page, struct wd_item *items, int n)
{
	pte_t *ptep, orig;
	struct wd_req r;
	int rc, i;

	if (n < 1 || n > 8)
		return -EINVAL;
	for (i = 0; i < n; i++)
		if (((unsigned long)items[i].addr & PAGE_MASK) != page)
			return -EINVAL;
	rc = wd_walk_pte(page, &ptep);
	if (rc)
		return rc;
	orig = READ_ONCE(*ptep);
	if (!pte_write(orig)) {
		rc = wd_set_pte(ptep, pte_mkwrite(orig), page);
		if (rc)
			return rc;
	}
	memset(&r, 0, sizeof(r));
	r.n = n;
	for (i = 0; i < n; i++)
		r.items[i] = items[i];
	atomic_set(&patch_cpus, 0);
	rc = stop_machine(wd_patch_cb, &r, NULL);
	if (!pte_write(orig))
		wd_set_pte(ptep, orig, page);
	return rc;
}

static u32 wd_mkb(s64 delta)
{
	return 0x94000000u | (((u64)delta >> 2) & 0x03ffffffu);
}

static unsigned long wd_b_target(unsigned long site, u32 insn)
{
	s64 d = (s64)(insn & 0x03ffffffu);

	if (d & 0x02000000)
		d -= 0x04000000;
	return (unsigned long)((s64)site + d * 4);
}

/* ------------------------------------------------------------------ */
/* install / remove                                                    */
/* ------------------------------------------------------------------ */
static int wd_install(void)
{
	struct wd_item items[1];
	unsigned long stub = (unsigned long)wdkill_stub;
	int i, done = 0, rc;

	if (stub < MODULES_VADDR || stub >= MODULES_END)
		return -ERANGE;
	if (READ_ONCE(*(u32 *)stub) != WD_INS_MOV_X0_X2 ||
	    READ_ONCE(*(u32 *)(stub + 4)) != WD_INS_RET) {
		pr_err("wdkill: stub body unexpected (%08x %08x)\n",
		       READ_ONCE(*(u32 *)stub), READ_ONCE(*(u32 *)(stub + 4)));
		return -EINVAL;
	}

	for (i = 0; i < WD_SITE_N; i++) {
		unsigned long site = g_base + wd_sites[i].bl_off;
		s64 d = (s64)stub - (s64)site;
		u32 w;

		if (d < -(1 << 27) || d >= (1 << 27)) {
			pr_err("wdkill: site %d out of B range (d=%lld)\n", i, d);
			rc = -ERANGE;
			goto rollback;
		}
		if (wd_rd32(site, &g_orig[i])) {
			rc = -EFAULT;
			goto rollback;
		}
		w = wd_mkb(d);
		if (wd_b_target(site, w) != stub) {
			pr_err("wdkill: branch self-check failed at %d\n", i);
			rc = -EINVAL;
			goto rollback;
		}
		g_patched[i] = w;
		items[0].addr = (void *)site;
		items[0].insn = w;
		rc = wd_patch_words(site & PAGE_MASK, items, 1);
		if (rc) {
			pr_err("wdkill: patch site %d failed: %d\n", i, rc);
			goto rollback;
		}
		done = i + 1;
		wd_rep("patched %-52s @%#08x  %08x -> %08x\n",
		       wd_sites[i].name, wd_sites[i].bl_off, g_orig[i], w);
	}

	/* read back through the normal (RO) mapping */
	for (i = 0; i < WD_SITE_N; i++) {
		u32 got;

		if (wd_rd32(g_base + wd_sites[i].bl_off, &got) ||
		    got != g_patched[i]) {
			pr_err("wdkill: readback mismatch at site %d\n", i);
			rc = -EIO;
			goto rollback;
		}
	}
	installed = true;
	wd_rep("INSTALLED: 7/7 wrappers diverted to wdkill_stub (no user copy)\n");
	return 0;

rollback:
	for (i = 0; i < done; i++) {
		items[0].addr = (void *)(g_base + wd_sites[i].bl_off);
		items[0].insn = g_orig[i];
		wd_patch_words((g_base + wd_sites[i].bl_off) & PAGE_MASK,
			       items, 1);
	}
	wd_rep("ROLLED BACK after failure (%d sites restored)\n", done);
	return rc;
}

static void wd_uninstall(void)
{
	struct wd_item items[1];
	unsigned long base;
	int i, restored = 0, skipped = 0;

	if (!installed)
		return;
	base = g_base;
	/* if mt_wifi went away and came back, our saved words are meaningless */
	if (g_mtwifi && (unsigned long)g_mtwifi->core_layout.base != base) {
		pr_warn("wdkill: mt_wifi base changed (%016lx -> %016lx), skip restore\n",
			base, (unsigned long)g_mtwifi->core_layout.base);
		installed = false;
		return;
	}
	for (i = 0; i < WD_SITE_N; i++) {
		unsigned long site = base + wd_sites[i].bl_off;
		u32 got = 0;

		if (wd_rd32(site, &got) || got != g_patched[i]) {
			pr_warn("wdkill: site %d changed by someone else (%08x), skip\n",
				i, got);
			skipped++;
			continue;
		}
		items[0].addr = (void *)site;
		items[0].insn = g_orig[i];
		if (wd_patch_words(site & PAGE_MASK, items, 1)) {
			pr_err("wdkill: restore site %d FAILED\n", i);
			skipped++;
			continue;
		}
		if (wd_rd32(site, &got) || got != g_orig[i]) {
			pr_err("wdkill: restore readback mismatch at site %d\n", i);
			skipped++;
			continue;
		}
		restored++;
	}
	pr_info("wdkill: restored %d/%d sites, %d skipped\n", restored,
		WD_SITE_N, skipped);
	installed = false;
}

/* ------------------------------------------------------------------ */
/* /proc/wdkill                                                        */
/* ------------------------------------------------------------------ */
static int wd_show(struct seq_file *m, void *v)
{
	seq_printf(m, "wdkill v1.0: %s\n",
		   installed ? "PATCHED" :
		   (dryrun ? (g_valid ? "dryrun-VALID" : "dryrun-INVALID") :
		    (g_valid ? "validated" : "not-validated")));
	seq_printf(m, "method=%s located=%d valid=%d base=%016lx\n",
		   g_method, g_located, g_valid, g_base);
	seq_printf(m, "stub=%016lx (%08x %08x)\n", (unsigned long)wdkill_stub,
		   READ_ONCE(*(u32 *)wdkill_stub),
		   READ_ONCE(*(u32 *)((unsigned long)wdkill_stub + 4)));
	seq_puts(m, g_report);
	return 0;
}

static int wd_open(struct inode *inode, struct file *file)
{
	return single_open(file, wd_show, NULL);
}

static const struct proc_ops wd_pops = {
	.proc_open	= wd_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* ------------------------------------------------------------------ */
static int __init wdkill_init(void)
{
	int rc;

	/* struct module layout gate: the device .config is byte-identical to the
	 * build tree's (tmpfiles/an4/config.gz vs .config, 5163/5163 lines), so
	 * these offsets are the device's.  A future header/config change must
	 * fail the BUILD, not read a wrong field at load time. */
	BUILD_BUG_ON(offsetof(struct module, state) != 0);
	BUILD_BUG_ON(offsetof(struct module, list) != 8);
	BUILD_BUG_ON(offsetof(struct module, name) != 24);
	BUILD_BUG_ON(offsetof(struct module, core_layout) != 320);

	wd_rep("=== wdkill v1.0 %s ===\n", dryrun ? "(dryrun)" : "");
	rc = wd_locate();
	if (rc) {
		pr_err("wdkill: locate failed: %d\n", rc);
		if (!dryrun)
			goto out_put;	/* also releases g_mtwifi if taken */
		wd_rep("dryrun: continuing without a base\n");
	}
	if (g_located) {
		rc = wd_validate();
		if (rc && !dryrun) {
			pr_err("wdkill: validation failed, refusing to load\n");
			goto out_put;
		}
	}

	if (!dryrun) {
		if (!g_valid) {
			rc = -EINVAL;
			goto out_put;
		}
		rc = wd_install();
		if (rc)
			goto out_put;
		pr_info("wdkill: INSTALLED base=%016lx stub=%px\n", g_base,
			wdkill_stub);
	} else {
		pr_info("wdkill: DRYRUN complete, nothing patched\n");
	}

	wd_pe = proc_create("wdkill", 0444, NULL, &wd_pops);
	if (!wd_pe) {
		rc = -ENOMEM;
		goto out_uninstall;
	}
	pr_info("wdkill: %s", g_report);
	return 0;

out_uninstall:
	wd_uninstall();
out_put:
	if (g_mtwifi) {
		module_put(g_mtwifi);
		g_mtwifi = NULL;
	}
	pr_err("wdkill: init failed: %d\n", rc);
	return rc;
}

static void __exit wdkill_exit(void)
{
	wd_uninstall();
	if (wd_pe)
		proc_remove(wd_pe);
	if (g_mtwifi) {
		module_put(g_mtwifi);
		g_mtwifi = NULL;
	}
	pr_info("wdkill: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(wdkill_init);
module_exit(wdkill_exit);

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
