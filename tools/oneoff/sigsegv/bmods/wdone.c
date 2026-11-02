// SPDX-License-Identifier: GPL-2.0
// wdone.ko v1.0 -- ONE-SHOT semantics for mt_wifi's 4 inline cached-usrptr sites.
//
// Source analysis: _local/investigations/sigsegv-tools/phase-AB/N2b-uaccess-sites.md
//   N2b §7.1: four inline __arch_copy_to_user sites take dst from a persistent
//   descriptor field `[xStruct + 0x10]` (layout {buf@+0x10, out_len@+0x18}):
//
//     site .text off   ldr (patch point)          struct base   dst
//     0x2976d8         0x297690 ldr x24,[x22,#0x10]  x22          x24
//     0x1f9864         0x1f9818 ldr x22,[x20,#0x10]  x20          x22
//     0x33bc64         0x33bc28 ldr x4, [x19,#0x10]  x19          x4
//     0x5b7e0          0x5b678  ldr x19,[x23,#0x10]  x23          x19
//
//   Root cause (N2b §5.1): the descriptor is per-adapter and resident; the
//   cached user pointer is written once and reused.  A path that reaches the
//   copy without refreshing +0x10 writes to the PREVIOUS caller's user VA.
//
// This module gives each site "one-shot" semantics: the field is read and then
// cleared in the same trampoline, so a stale pointer can never be used twice.
//
//   wdone_os_<site>:
//       ldr xD, [xS, #0x10]     ; the displaced instruction, verbatim
//       str xzr, [xS, #0x10]    ; one-shot: invalidate the cached pointer
//       b   <site + 4>          ; patched at init
//
// The site's `ldr` becomes `b wdone_os_<site>` (one 4-byte word per site, the
// same single-word replacement model tuphook.ko uses and has proven on-device).
// The trampoline is straight-line, builds no frame, touches no register other
// than the destination register the original ldr already wrote, and never
// reads or writes user memory.
//
// WHY NOT A NULL dst (N2b §7.0 style): CONFIG_HARDENED_USERCOPY=y and
// CONFIG_PANIC_ON_OOPS=y (device IKCONFIG == build tree .config, verified).
// A NULL dst reaching __check_object_size() -> usercopy_abort("null address")
// -> BUG() -> panic -> reboot.  Here dst is never nulled; only the *cache
// field* is cleared, and dst is the value that was just loaded from it.
//
// ===================== what is validated before any write =====================
// Every site is pinned by a 3-4 word fingerprint (the ldr word itself encodes
// base register + destination register + offset, so a different vendor build
// cannot silently match):
//
//   0x297690: mov w2,#1 | ldr x24,[x22,#0x10] | mov x0,x25 | ldrh w21,[x22,#0x18]
//   0x1f9818: b <back> | ldr x22,[x20,#0x10] | and x19,x0,#0xffff | mov w2,#1
//   0x33bc28: (BL)     | ldr x4, [x19,#0x10] | mov w0,#0xf6 | strh w0,[x19,#0x18]
//   0x5b678:  tbnz     | ldr x19,[x23,#0x10] | mov w0,#8   | strh w0,[x23,#0x18]
//   (the word before 0x33bc28 is a relocated `bl` and is deliberately NOT part
//    of the fingerprint: the loader patches it at load time)
//
// Any mismatch refuses the load with -EINVAL and prints the actual words.
// dryrun=1 always loads and reports so the operator can read /proc/wdone.
//
// Module base resolution, text-writing window (TTBR1 pgd walk + PTE flip +
// stop_machine + dc/ic maintenance) and the /proc report are the same proven
// machinery as wdkill.ko / tuphook.ko; see REVIEW-wdone.md.
//
// Module params:
//   dryrun=1   locate + validate + report only; not one byte is written
//
// rmmod restores the four `ldr` words and the four back-branches, verifies the
// readback, and drops the reference taken on mt_wifi.
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
MODULE_DESCRIPTION("wdone: one-shot semantics for mt_wifi inline cached user pointers (v1.0)");
MODULE_AUTHOR("chr431");

#define WD_SITE_N		4
#define WD_TEXT_SIG_LEN		32
#define WD_NM			256

/* the four displaced ldr words (N2b §7.1) */
#define WD_INS_LDR_2976		0xf9400ad8u	/* ldr x24,[x22,#0x10] */
#define WD_INS_LDR_1F98		0xf9400a96u	/* ldr x22,[x20,#0x10] */
#define WD_INS_LDR_33BC		0xf9400a64u	/* ldr x4, [x19,#0x10] */
#define WD_INS_LDR_5B67		0xf9400af3u	/* ldr x19,[x23,#0x10] */

/* the one-shot store each trampoline executes */
#define WD_INS_STR_2976		0xf9000adfu	/* str xzr,[x22,#0x10] */
#define WD_INS_STR_1F98		0xf9000a9fu	/* str xzr,[x20,#0x10] */
#define WD_INS_STR_33BC		0xf9000a7fu	/* str xzr,[x19,#0x10] */
#define WD_INS_STR_5B67		0xf9000affu	/* str xzr,[x23,#0x10] */

struct wd_exp {
	s16 delta;
	u32 word;
};

struct wd_site {
	const char *name;
	u32 ldr_off;
	u32 ldr_want;
	u32 str_want;
	int nexp;
	struct wd_exp exp[4];
};

static const struct wd_site wd_sites[WD_SITE_N] = {
	{ "RTMP_COM_IoctlHandle+0xc20 [adapter+0xd6f8] (risk #1)",
	  0x297690, WD_INS_LDR_2976, WD_INS_STR_2976, 4,
	  { { -0x04, 0x52800022 }, { 0x00, WD_INS_LDR_2976 },
	    { +0x04, 0xaa1903e0 }, { +0x08, 0x794032d5 } } },
	{ "AP_E2PROM_IOCTL_PostCtrl+0xfc [arg0+0x10]",
	  0x1f9818, WD_INS_LDR_1F98, WD_INS_STR_1F98, 4,
	  { { -0x04, 0x17fffff2 }, { 0x00, WD_INS_LDR_1F98 },
	    { +0x04, 0x92403c13 }, { +0x08, 0x52800022 } } },
	{ "ZeroWaitDfsQueryCmdHandler+0x48 [arg1+0x10]",
	  0x33bc28, WD_INS_LDR_33BC, WD_INS_STR_33BC, 3,
	  { { 0x00, WD_INS_LDR_33BC }, { +0x04, 0x52801ec0 },
	    { +0x08, 0x79003260 }, { 0, 0 } } },
	{ "ate_cmd_proc+0x184 [arg2+0x10]",
	  0x5b678, WD_INS_LDR_5B67, WD_INS_STR_5B67, 4,
	  { { -0x04, 0x37180880 }, { 0x00, WD_INS_LDR_5B67 },
	    { +0x04, 0x52800100 }, { +0x08, 0x790032e0 } } },
};

static int dryrun;
module_param(dryrun, int, 0444);
MODULE_PARM_DESC(dryrun, "1 = locate + validate + report only, patch nothing");

/* ---- one-shot trampolines: displaced ldr + clear + back-branch ---- */
asm(
".pushsection .text\n"
".balign 4096\n"
".globl wdone_os_2976\n"
"wdone_os_2976:\n"
"	ldr	x24, [x22, #0x10]\n"
"	str	xzr, [x22, #0x10]\n"
".globl wdone_back_2976\n"
"wdone_back_2976:\n"
"	b	.\n"
".globl wdone_os_1f98\n"
"wdone_os_1f98:\n"
"	ldr	x22, [x20, #0x10]\n"
"	str	xzr, [x20, #0x10]\n"
".globl wdone_back_1f98\n"
"wdone_back_1f98:\n"
"	b	.\n"
".globl wdone_os_33bc\n"
"wdone_os_33bc:\n"
"	ldr	x4, [x19, #0x10]\n"
"	str	xzr, [x19, #0x10]\n"
".globl wdone_back_33bc\n"
"wdone_back_33bc:\n"
"	b	.\n"
".globl wdone_os_5b67\n"
"wdone_os_5b67:\n"
"	ldr	x19, [x23, #0x10]\n"
"	str	xzr, [x23, #0x10]\n"
".globl wdone_back_5b67\n"
"wdone_back_5b67:\n"
"	b	.\n"
".balign 16\n"
".popsection\n"
);

extern char wdone_os_2976[], wdone_back_2976[];
extern char wdone_os_1f98[], wdone_back_1f98[];
extern char wdone_os_33bc[], wdone_back_33bc[];
extern char wdone_os_5b67[], wdone_back_5b67[];

static char *const wd_stubs[WD_SITE_N] = {
	wdone_os_2976, wdone_os_1f98, wdone_os_33bc, wdone_os_5b67,
};
static char *const wd_backs[WD_SITE_N] = {
	wdone_back_2976, wdone_back_1f98, wdone_back_33bc, wdone_back_5b67,
};

/* ---- state ---- */
static bool installed;
static unsigned long g_base;
static u32 g_orig[WD_SITE_N];		/* original ldr words */
static u32 g_patched[WD_SITE_N];	/* `b stub` words written at the sites */
static u32 g_orig_back[WD_SITE_N];	/* original `b .` words in our text */
static u32 g_patched_back[WD_SITE_N];	/* back-branch words written */
static char g_report[6144];
static int g_note;
static struct proc_dir_entry *wd_pe;
static struct module *g_mtwifi;
static const char *g_method = "none";
static int g_located;
static int g_valid;

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
/* module base resolution (identical to wdkill.ko)                     */
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

static int wd_check_site(int i, unsigned long base)
{
	const struct wd_site *s = &wd_sites[i];
	u32 got;
	int k, ok = 1;

	for (k = 0; k < s->nexp; k++) {
		unsigned long a = base + s->ldr_off + s->exp[k].delta;

		if (wd_rd32(a, &got)) {
			wd_rep("  %-50s @%#08x %+#06x  UNREADABLE\n",
			       s->name, s->ldr_off, s->exp[k].delta);
			ok = 0;
			continue;
		}
		if (got != s->exp[k].word) {
			wd_rep("  %-50s @%#08x %+#06x  got %08x want %08x  MISMATCH\n",
			       s->name, s->ldr_off, s->exp[k].delta, got,
			       s->exp[k].word);
			ok = 0;
		} else {
			wd_rep("  %-50s @%#08x %+#06x  got %08x want %08x  ok\n",
			       s->name, s->ldr_off, s->exp[k].delta, got,
			       s->exp[k].word);
		}
	}
	return ok ? 0 : -EINVAL;
}

static int wd_locate(void)
{
	struct module *m = NULL;
	unsigned long base = 0, scan;
	char nm[WD_NM];
	int rc;

	wd_rep("wdone v1.0: locate\n");
	rc = wd_find_mt_wifi(&m);
	if (!rc && !try_module_get(m)) {
		wd_rep("module-list: mt_wifi found but refcount get failed\n");
		rc = -ENOENT;
		m = NULL;
	}
	if (!rc) {
		g_mtwifi = m;
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
	wd_sym(base + wd_sites[0].ldr_off, nm, sizeof(nm));
	wd_rep("sprint_symbol(base+%#x) = %s\n", wd_sites[0].ldr_off, nm);
	if (!strstr(nm, "[mt_wifi]")) {
		wd_rep("REFUSING: base+%#x does not resolve into mt_wifi\n",
		       wd_sites[0].ldr_off);
		return -EINVAL;
	}
	g_base = base;
	g_located = 1;
	return 0;
}

static int wd_validate(void)
{
	int i, bad = 0;

	wd_rep("fingerprints (4 inline sites):\n");
	for (i = 0; i < WD_SITE_N; i++) {
		if (wd_check_site(i, g_base))
			bad++;
	}
	if (bad) {
		wd_rep("VALIDATION FAILED: %d/%d sites mismatch\n", bad,
		       WD_SITE_N);
		return -EINVAL;
	}
	wd_rep("VALIDATION OK: 4/4 inline sites match the N2b snapshot\n");
	g_valid = 1;
	return 0;
}

/* ------------------------------------------------------------------ */
/* page-table window (tuphook-proven)                                  */
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
	return 0x14000000u | (((u64)delta >> 2) & 0x03ffffffu);
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
static int wd_check_stubs(void)
{
	int i;

	for (i = 0; i < WD_SITE_N; i++) {
		u32 a, b;

		if (wd_rd32((unsigned long)wd_stubs[i], &a) ||
		    wd_rd32((unsigned long)wd_stubs[i] + 4, &b)) {
			pr_err("wdone: stub %d unreadable\n", i);
			return -EFAULT;
		}
		if (a != wd_sites[i].ldr_want || b != wd_sites[i].str_want) {
			pr_err("wdone: stub %d body unexpected (%08x %08x want %08x %08x)\n",
			       i, a, b, wd_sites[i].ldr_want,
			       wd_sites[i].str_want);
			return -EINVAL;
		}
	}
	return 0;
}

static int wd_install(void)
{
	struct wd_item items[WD_SITE_N];
	unsigned long stubpage = (unsigned long)wdone_os_2976 & PAGE_MASK;
	int i, nback = 0, ndone = 0, rc;

	rc = wd_check_stubs();
	if (rc)
		return rc;

	/* the four trampolines must share one page (single writable window) */
	for (i = 0; i < WD_SITE_N; i++)
		if (((unsigned long)wd_stubs[i] & PAGE_MASK) != stubpage ||
		    ((unsigned long)wd_backs[i] & PAGE_MASK) != stubpage) {
			pr_err("wdone: trampoline block straddles a page\n");
			return -EINVAL;
		}

	/* 1. arm the back-branches first: no site may enter a half-armed stub */
	for (i = 0; i < WD_SITE_N; i++) {
		unsigned long site = g_base + wd_sites[i].ldr_off;
		unsigned long back = (unsigned long)wd_backs[i];
		s64 d = (s64)(site + 4) - (s64)back;
		u32 w;

		if (d < -(1 << 27) || d >= (1 << 27)) {
			pr_err("wdone: back-branch %d out of range (%lld)\n", i, d);
			rc = -ERANGE;
			goto rollback_back;
		}
		if (wd_rd32(back, &g_orig_back[i])) {
			rc = -EFAULT;
			goto rollback_back;
		}
		w = wd_mkb(d);
		if (wd_b_target(back, w) != site + 4) {
			pr_err("wdone: back-branch self-check failed at %d\n", i);
			rc = -EINVAL;
			goto rollback_back;
		}
		g_patched_back[i] = w;
		items[i].addr = (void *)back;
		items[i].insn = w;
		nback = i + 1;
	}
	rc = wd_patch_words(stubpage, items, nback);
	if (rc) {
		pr_err("wdone: trampoline patch failed: %d\n", rc);
		goto rollback_back;
	}
	for (i = 0; i < nback; i++) {
		u32 got = 0;

		if (wd_rd32((unsigned long)wd_backs[i], &got) ||
		    got != g_patched_back[i]) {
			pr_err("wdone: back-branch readback mismatch at %d\n", i);
			rc = -EIO;
			goto rollback_back;
		}
		wd_rep("armed  %-50s back %016lx %08x -> %08x\n",
		       wd_sites[i].name, (unsigned long)wd_backs[i],
		       g_orig_back[i], g_patched_back[i]);
	}

	/* 2. divert the four sites */
	for (i = 0; i < WD_SITE_N; i++) {
		unsigned long site = g_base + wd_sites[i].ldr_off;
		unsigned long stub = (unsigned long)wd_stubs[i];
		s64 d = (s64)stub - (s64)site;
		u32 w;

		if (d < -(1 << 27) || d >= (1 << 27)) {
			pr_err("wdone: site %d out of B range (%lld)\n", i, d);
			rc = -ERANGE;
			goto rollback_sites;
		}
		if (wd_rd32(site, &g_orig[i])) {
			rc = -EFAULT;
			goto rollback_sites;
		}
		w = wd_mkb(d);
		if (wd_b_target(site, w) != stub) {
			pr_err("wdone: site branch self-check failed at %d\n", i);
			rc = -EINVAL;
			goto rollback_sites;
		}
		g_patched[i] = w;
		items[0].addr = (void *)site;
		items[0].insn = w;
		rc = wd_patch_words(site & PAGE_MASK, items, 1);
		if (rc) {
			pr_err("wdone: patch site %d failed: %d\n", i, rc);
			goto rollback_sites;
		}
		ndone = i + 1;
		wd_rep("site   %-50s @%#08x %08x -> %08x\n",
		       wd_sites[i].name, wd_sites[i].ldr_off, g_orig[i], w);
	}

	for (i = 0; i < WD_SITE_N; i++) {
		u32 got;

		if (wd_rd32(g_base + wd_sites[i].ldr_off, &got) ||
		    got != g_patched[i]) {
			pr_err("wdone: readback mismatch at site %d\n", i);
			rc = -EIO;
			goto rollback_sites;
		}
	}
	installed = true;
	wd_rep("INSTALLED: 4/4 inline sites now one-shot (ldr+str xzr)\n");
	return 0;

rollback_sites:
	for (i = 0; i < ndone; i++) {
		items[0].addr = (void *)(g_base + wd_sites[i].ldr_off);
		items[0].insn = g_orig[i];
		wd_patch_words((g_base + wd_sites[i].ldr_off) & PAGE_MASK,
			       items, 1);
	}
rollback_back:
	for (i = 0; i < nback; i++) {
		items[0].addr = (void *)wd_backs[i];
		items[0].insn = g_orig_back[i];
		wd_patch_words((unsigned long)wd_backs[i] & PAGE_MASK, items, 1);
	}
	wd_rep("ROLLED BACK after failure (sites=%d back=%d)\n", ndone, nback);
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
	if (g_mtwifi && (unsigned long)g_mtwifi->core_layout.base != base) {
		pr_warn("wdone: mt_wifi base changed, skip restore\n");
		installed = false;
		return;
	}
	/* sites first: stop new entries into the trampolines */
	for (i = 0; i < WD_SITE_N; i++) {
		unsigned long site = base + wd_sites[i].ldr_off;
		u32 got = 0;

		if (wd_rd32(site, &got) || got != g_patched[i]) {
			pr_warn("wdone: site %d changed by someone else (%08x), skip\n",
				i, got);
			skipped++;
			continue;
		}
		items[0].addr = (void *)site;
		items[0].insn = g_orig[i];
		if (wd_patch_words(site & PAGE_MASK, items, 1) ||
		    wd_rd32(site, &got) || got != g_orig[i]) {
			pr_err("wdone: restore site %d FAILED\n", i);
			skipped++;
			continue;
		}
		restored++;
	}
	for (i = 0; i < WD_SITE_N; i++) {
		u32 got = 0;

		if (wd_rd32((unsigned long)wd_backs[i], &got) ||
		    got != g_patched_back[i])
			continue;
		items[0].addr = (void *)wd_backs[i];
		items[0].insn = g_orig_back[i];
		wd_patch_words((unsigned long)wd_backs[i] & PAGE_MASK, items, 1);
	}
	pr_info("wdone: restored %d/%d sites, %d skipped\n", restored,
		WD_SITE_N, skipped);
	installed = false;
}

/* ------------------------------------------------------------------ */
/* /proc/wdone                                                         */
/* ------------------------------------------------------------------ */
static int wd_show(struct seq_file *m, void *v)
{
	int i;

	seq_printf(m, "wdone v1.0: %s\n",
		   installed ? "PATCHED" :
		   (dryrun ? (g_valid ? "dryrun-VALID" : "dryrun-INVALID") :
		    (g_valid ? "validated" : "not-validated")));
	seq_printf(m, "method=%s located=%d valid=%d base=%016lx\n",
		   g_method, g_located, g_valid, g_base);
	for (i = 0; i < WD_SITE_N; i++)
		seq_printf(m, "tramp%d=%016lx [%08x %08x %08x]\n", i,
			   (unsigned long)wd_stubs[i],
			   READ_ONCE(*(u32 *)wd_stubs[i]),
			   READ_ONCE(*(u32 *)((unsigned long)wd_stubs[i] + 4)),
			   READ_ONCE(*(u32 *)((unsigned long)wd_stubs[i] + 8)));
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
static int __init wdone_init(void)
{
	int rc;

	/* struct module layout gate (same reasoning as wdkill.ko: device IKCONFIG
	 * == build tree .config, verified line for line) */
	BUILD_BUG_ON(offsetof(struct module, state) != 0);
	BUILD_BUG_ON(offsetof(struct module, list) != 8);
	BUILD_BUG_ON(offsetof(struct module, name) != 24);
	BUILD_BUG_ON(offsetof(struct module, core_layout) != 320);

	wd_rep("=== wdone v1.0 %s ===\n", dryrun ? "(dryrun)" : "");
	rc = wd_locate();
	if (rc) {
		pr_err("wdone: locate failed: %d\n", rc);
		if (!dryrun)
			goto out_put;	/* also releases g_mtwifi if taken */
		wd_rep("dryrun: continuing without a base\n");
	}
	if (g_located) {
		rc = wd_validate();
		if (rc && !dryrun) {
			pr_err("wdone: validation failed, refusing to load\n");
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
		pr_info("wdone: INSTALLED base=%016lx\n", g_base);
	} else {
		pr_info("wdone: DRYRUN complete, nothing patched\n");
	}

	wd_pe = proc_create("wdone", 0444, NULL, &wd_pops);
	if (!wd_pe) {
		rc = -ENOMEM;
		goto out_uninstall;
	}
	pr_info("wdone: %s", g_report);
	return 0;

out_uninstall:
	wd_uninstall();
out_put:
	if (g_mtwifi) {
		module_put(g_mtwifi);
		g_mtwifi = NULL;
	}
	pr_err("wdone: init failed: %d\n", rc);
	return rc;
}

static void __exit wdone_exit(void)
{
	wd_uninstall();
	if (wd_pe)
		proc_remove(wd_pe);
	if (g_mtwifi) {
		module_put(g_mtwifi);
		g_mtwifi = NULL;
	}
	pr_info("wdone: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(wdone_init);
module_exit(wdone_exit);

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
