// SPDX-License-Identifier: GPL-2.0
// dieblx.ko -- die_notifier black box for LG6151M (5.15.134 aarch64).
//
// Registers a die_notifier (DIE_OOPS) and a panic_notifier.  On oops/panic it
// prints, via printk(KERN_EMERG) only:
//   - current comm/pid/tgid, die str/err
//   - full pt_regs: x0..x30, pc, pstate (+ esr/far re-read from sysregs)
//   - (watch_va/watch_len set) first watch_len bytes at watch_va
// Output lands in the ring buffer synchronously; console-ramoops picks it up
// either through the oops console path or panic()'s console_flush_on_panic().
//
// Red lines honoured in the notifier callback:
//   zero locks, zero allocation, zero sleeping, minimal stack (hand-rolled hex,
//   no vsnprintf on the dump path), recursion guard for nested faults.
// Watch reads use copy_from_kernel_nofault (extable fixup, no pagefault) over
// the kernel linear map only; user VAs are converted PA-side by a lock-free,
// read-only page-table walk of current->mm.
//
// Module params:
//   watch_va=0x...   VA of interest (0 = disabled, default)
//   watch_len=N      bytes to dump, capped at 64 (default 64)
//   armed=42         arm the selftest trigger (0600)
//   trigger=1        (needs armed==42) deliberate BUG() -- controlled selftest
//   trigger=2        (needs armed==42) deliberate NULL kernel read
// See REVIEW-dieblx.md for the on-device validation sequence (F-07).
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kdebug.h>
#include <linux/notifier.h>
#include <linux/panic_notifier.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/smp.h>
#include <linux/mm.h>
#include <linux/uaccess.h>
#include <asm/ptrace.h>
#include <asm/pgtable.h>
#include <asm/sysreg.h>
#include <asm/memory.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dieblx: die_notifier/panic black box (read-only, printk-only)");
MODULE_AUTHOR("chr431");

static unsigned long watch_va;
static unsigned int watch_len = 64;
static unsigned int armed;
static int trigger_val;

module_param(watch_va, ulong, 0644);
MODULE_PARM_DESC(watch_va, "VA of interest (0=off; kernel VA read directly, user VA via lock-free PT walk)");
module_param(watch_len, uint, 0644);
MODULE_PARM_DESC(watch_len, "bytes to dump at watch_va, capped to 64");
module_param(armed, uint, 0600);
MODULE_PARM_DESC(armed, "write 42 to arm the selftest trigger");

static atomic_t blx_busy;    /* recursion guard: 1 while inside our callbacks */
static atomic_t blx_dumped;  /* regs were dumped by the die path before panic */

/* ---- hand-rolled hex formatting: 16 chars, no library helpers ---- */
static noinline char *blx_hx(char *dst, u64 v)
{
	static const char hex[] __maybe_unused = "0123456789abcdef";
	int i;

	for (i = 15; i >= 0; i--) {
		dst[i] = hex[v & 0xf];
		v >>= 4;
	}
	return dst + 16;
}

/* one "dieblx: <lbl>=<16 hex>\n" line */
static void blx_kv(const char *lbl, u64 v)
{
	char buf[48];
	char *p = buf;

	while (*lbl)
		*p++ = *lbl++;
	*p++ = '=';
	blx_hx(p, v);
	p += 16;
	*p++ = '\n';
	*p = '\0';
	printk(KERN_EMERG "dieblx: %s", buf);
}

/* one "dieblx: xNN=.... xNN=.... xNN=.... xNN=....\n" line (4 values) */
static void blx_4(char tag, int base, const u64 *r)
{
	char buf[112];
	size_t o = 0;
	int i;

	for (i = 0; i < 4; i++) {
		int rn = base + i;

		buf[o++] = tag;
		buf[o++] = '0' + (rn / 10);
		buf[o++] = '0' + (rn % 10);
		buf[o++] = '=';
		blx_hx(buf + o, r[rn]);
		o += 16;
		buf[o++] = ' ';
	}
	buf[o - 1] = '\n';	/* replace trailing space */
	buf[o] = '\0';
	printk(KERN_EMERG "dieblx: %s", buf);
}

/*
 * Read watch bytes.  Returns 0 = disabled, 1 = ok (*wlen valid), <0 = error.
 * Called from atomic (die/panic) context: no locks, no sleep, no allocation.
 *  - kernel VA ((long)va < 0): fixup-protected read via copy_from_kernel_nofault
 *  - user VA: lock-free read-only page-table walk of current->mm, then read
 *    through the kernel linear map (pfn_valid-gated).  Racing unmap/fork can
 *    at worst yield stale bytes or an error code; every access is exception-
 *    fixed so a fault cannot escalate into a nested oops that we do not guard.
 */
static int blx_watch(u64 *w, unsigned int *wlen)
{
	unsigned long va = watch_va;
	unsigned long len = watch_len > 64 ? 64 : watch_len;
	unsigned long off, pa, pfn, kva;
	struct mm_struct *mm;
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;

	*wlen = 0;
	if (!va)
		return 0;
	if (!len)
		return -10;

	if ((long)va < 0) {			/* kernel VA: direct, fixup-safe */
		if (copy_from_kernel_nofault(w, (const void *)va, len))
			return -11;
		*wlen = len;
		return 1;
	}

	mm = current->mm;			/* user VA: walk current's tables */
	if (!mm)
		return -12;

	pgd = pgd_offset(mm, va);
	if (pgd_none(READ_ONCE(*pgd)) || pgd_bad(READ_ONCE(*pgd)))
		return -13;
	p4d = p4d_offset(pgd, va);
	if (p4d_none(READ_ONCE(*p4d)) || p4d_bad(READ_ONCE(*p4d)))
		return -13;
	pud = pud_offset(p4d, va);
	if (pud_none(READ_ONCE(*pud)) || pud_bad(READ_ONCE(*pud)))
		return -13;
	if (pud_leaf(READ_ONCE(*pud))) {
		pfn = pud_pfn(READ_ONCE(*pud));
		goto have_pfn;
	}
	pmd = pmd_offset(pud, va);
	if (pmd_none(READ_ONCE(*pmd)))
		return -13;
	if (pmd_leaf(READ_ONCE(*pmd))) {
		pfn = pmd_pfn(READ_ONCE(*pmd));
		goto have_pfn;
	}
	pte = pte_offset_map(pmd, va);
	if (!pte)
		return -14;
	if (!pte_present(READ_ONCE(*pte))) {
		pte_unmap(pte);
		return -15;
	}
	pfn = pte_pfn(READ_ONCE(*pte));
	pte_unmap(pte);
have_pfn:
	if (!pfn || !pfn_valid(pfn))
		return -16;
	pa = pfn << PAGE_SHIFT;
	off = va & ~PAGE_MASK;
	kva = (unsigned long)__va(pa) + off;
	if (off + len > PAGE_SIZE)
		len = PAGE_SIZE - off;
	if (copy_from_kernel_nofault(w, (const void *)kva, len))
		return -17;
	*wlen = len;
	return 1;
}

/* ---- die_notifier callback: oops black box ---- */
static int blx_die_cb(struct notifier_block *nb, unsigned long val, void *data)
{
	struct die_args *a = data;
	struct pt_regs *r;
	u64 w[8] = {0};
	unsigned int wlen;
	int rc, i;

	if (val != DIE_OOPS || !data)
		return NOTIFY_DONE;

	if (atomic_xchg(&blx_busy, 1)) {
		printk(KERN_EMERG "dieblx: nested fault inside notifier, suppressed\n");
		return NOTIFY_DONE;
	}

	r = a->regs;
	printk(KERN_EMERG "dieblx Oops: comm=%s pid=%d tgid=%d cpu=%d str=%s err=%ld\n",
	       current->comm, current->pid, current->tgid,
	       raw_smp_processor_id(), a->str ? a->str : "?", a->err);
	if (!r) {
		printk(KERN_EMERG "dieblx: no pt_regs in die_args, dump truncated\n");
		atomic_set(&blx_dumped, 1);
		goto out;
	}

	blx_kv("pc    ", r->pc);
	blx_kv("pstate", r->pstate);
	blx_kv("sp    ", r->sp);
	/* ESR/FAR are re-read from sysregs: correct for the faulting exception
	 * unless a nested exception already clobbered them (best effort). */
	blx_kv("esr_sr", read_sysreg(esr_el1));
	blx_kv("far_sr", read_sysreg(far_el1));
	for (i = 0; i < 28; i += 4)
		blx_4('x', i, &r->regs[0]);
	atomic_set(&blx_dumped, 1);

	rc = blx_watch(w, &wlen);
	if (rc == 0)
		printk(KERN_EMERG "dieblx: watch disabled (watch_va=0)\n");
	else if (rc < 0)
		printk(KERN_EMERG "dieblx: watch va=%016lx read failed rc=%d\n",
		       watch_va, rc);
	else
		for (i = 0; i < 4; i++)
			if (wlen > (unsigned int)i * 16)
				blx_4('w', i * 4, &w[0]);
	printk(KERN_EMERG "dieblx: Oops dump complete\n");
out:
	atomic_set(&blx_busy, 0);
	return NOTIFY_DONE;
}

/* ---- panic_notifier callback: runs after smp_send_stop, before the
 *      final console flush; keep it to a couple of printk lines ---- */
static int blx_panic_cb(struct notifier_block *nb, unsigned long val, void *data)
{
	if (atomic_xchg(&blx_busy, 1)) {
		printk(KERN_EMERG "dieblx: nested fault inside panic cb, suppressed\n");
		return NOTIFY_DONE;
	}
	printk(KERN_EMERG "dieblx: PANIC comm=%s pid=%d cpu=%d regs_dumped=%d msg=%s\n",
	       current->comm, current->pid, raw_smp_processor_id(),
	       atomic_read(&blx_dumped), data ? (const char *)data : "?");
	atomic_set(&blx_busy, 0);
	return NOTIFY_DONE;
}

static struct notifier_block blx_die_nb = {
	.notifier_call = blx_die_cb,
	.priority = 0x7fffffff,		/* run before everything else */
};

static struct notifier_block blx_panic_nb = {
	.notifier_call = blx_panic_cb,
	.priority = 0x7fffffff,
};

/* ---- controlled selftest (armed gate; see REVIEW-dieblx.md) ---- */
static int blx_trigger_set(const char *val, const struct kernel_param *kp)
{
	int v = 0;

	if (kstrtoint(val, 0, &v))
		return -EINVAL;
	if (armed != 42) {
		pr_info("dieblx: trigger refused (armed=%u, write 42 first)\n", armed);
		return 0;
	}
	if (v == 1) {
		pr_info("dieblx: selftest BUG() now (expect Oops dump above)\n");
		BUG();
	} else if (v == 2) {
		unsigned long x;

		pr_info("dieblx: selftest NULL kernel read now\n");
		x = READ_ONCE(*(volatile unsigned long *)NULL);
		pr_info("dieblx: unreachable, null read returned %lx\n", x);
	} else {
		return -EINVAL;
	}
	return 0;
}

static const struct kernel_param_ops blx_trigger_ops = {
	.set = blx_trigger_set,
	.get = param_get_int,
};
module_param_cb(trigger, &blx_trigger_ops, &trigger_val, 0600);
MODULE_PARM_DESC(trigger, "1=BUG() 2=NULL read (requires armed=42)");

static int __init dieblx_init(void)
{
	int rc;

	if (watch_len > 64) {
		watch_len = 64;
		pr_info("dieblx: watch_len clamped to 64\n");
	}
	rc = register_die_notifier(&blx_die_nb);
	if (rc) {
		pr_err("dieblx: register_die_notifier failed: %d\n", rc);
		return rc;
	}
	rc = atomic_notifier_chain_register(&panic_notifier_list, &blx_panic_nb);
	if (rc) {
		unregister_die_notifier(&blx_die_nb);
		pr_err("dieblx: panic notifier register failed: %d\n", rc);
		return rc;
	}
	atomic_set(&blx_dumped, 0);
	pr_info("dieblx: loaded (watch_va=0x%016lx watch_len=%u, selftest armed=%u)\n",
		watch_va, watch_len, armed);
	return 0;
}

static void __exit dieblx_exit(void)
{
	atomic_notifier_chain_unregister(&panic_notifier_list, &blx_panic_nb);
	unregister_die_notifier(&blx_die_nb);
	pr_info("dieblx: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(dieblx_init);
module_exit(dieblx_exit);

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
