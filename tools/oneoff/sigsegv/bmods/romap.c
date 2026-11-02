// SPDX-License-Identifier: GPL-2.0
// romap.ko -- read-only user-page diagnostics for LG6151M (5.15.134 aarch64).
//
//   echo "<pid> <hexva> [ref_hexva]" > /proc/romap
//     -> for the target VA (and a same-batch reference page, by default the
//        page holding the task's saved user sp from task_pt_regs): PTE walk
//        then struct page five-tuple  pfn / _refcount / _mapcount / flags /
//        mapping(+anon-file class)  -- D12 style comparison pair.
//   echo "ptregs <pid>" > /proc/romap
//     -> task_pt_regs(task) sp (highlighted) + all 31 GPRs + pc/pstate
//        -- D14 / H6 criteria (kernel-side saved user sp).
//   cat /proc/romap   -> last result (also mirrored to dmesg).
//
// Read-only: page tables are walked under mmap_read_lock (process context,
// sleeping allowed); struct page / kernel stack reads are plain loads of
// live kernel memory.  No text patching, no PTE writes, no notifier.
//
// Cross-task mm gate: mm_access()/ptrace_may_access() are NOT exported to
// modules in 5.15, so the equivalent gate implemented here is
// capable(CAP_SYS_PTRACE) + get_task_mm() (ref-held).  On this device the
// callers are root over SSH, which is exactly the population
// ptrace_may_access(PTRACE_MODE_ATTACH) would admit anyway.  Failures are
// reported as error lines, never BUG_ON/panic.
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/sched/task.h>
#include <linux/pid.h>
#include <linux/mm.h>
#include <linux/mm_types.h>
#include <linux/page-flags.h>
#include <linux/mutex.h>
#include <linux/capability.h>
#include <linux/stdarg.h>
#include <linux/pgtable.h>
#include <asm/pgtable.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("romap: read-only page-five-tuple + task_pt_regs diagnostics");
MODULE_AUTHOR("chr431");

static struct proc_dir_entry *pe;
static DEFINE_MUTEX(g_lock);
static char g_out[4096];
static size_t g_len;

/* ---- result buffer helpers (process context only) ---- */
static void out_reset(void)
{
	g_len = 0;
	g_out[0] = '\0';
}

static void out_append(const char *fmt, ...)
{
	va_list ap;
	int n;

	if (g_len + 1 >= sizeof(g_out))
		return;
	va_start(ap, fmt);
	n = vscnprintf(g_out + g_len, sizeof(g_out) - g_len, fmt, ap);
	va_end(ap);
	if (n > 0)
		g_len += n;
}

/* patrace-proven walk: 0 on success, fills *pa */
static int walk_va(struct mm_struct *mm, unsigned long va, unsigned long *pa)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;

	pgd = pgd_offset(mm, va);
	if (pgd_none(*pgd) || pgd_bad(*pgd))
		return -ENOENT;
	p4d = p4d_offset(pgd, va);
	if (p4d_none(*p4d) || p4d_bad(*p4d))
		return -ENOENT;
	pud = pud_offset(p4d, va);
	if (pud_none(*pud) || pud_bad(*pud))
		return -ENOENT;
	if (pud_leaf(*pud)) {
		*pa = (pud_pfn(*pud) << PAGE_SHIFT) | (va & (PUD_SIZE - 1));
		return 0;
	}
	pmd = pmd_offset(pud, va);
	if (pmd_none(*pmd))
		return -ENOENT;
	if (pmd_leaf(*pmd)) {
		*pa = (pmd_pfn(*pmd) << PAGE_SHIFT) | (va & (PMD_SIZE - 1));
		return 0;
	}
	pte = pte_offset_map(pmd, va);
	if (!pte)
		return -ENOENT;
	if (!pte_present(*pte)) {
		pte_unmap(pte);
		return -ENOENT;
	}
	*pa = (pte_pfn(*pte) << PAGE_SHIFT) | (va & ~PAGE_MASK);
	pte_unmap(pte);
	return 0;
}

/* D12: struct page five-tuple for the page backing va (mm read-locked) */
static void page_report(struct mm_struct *mm, const char *tag, unsigned long va)
{
	unsigned long pa = 0, pfn, fl;
	struct page *pg;
	void *mp;
	int ref, mapc;
	int rc;

	rc = walk_va(mm, va, &pa);
	if (rc) {
		out_append("romap %s va=%016lx walk_err=%d (unmapped/swap/none)\n",
			   tag, va, rc);
		return;
	}
	pfn = pa >> PAGE_SHIFT;
	if (!pfn_valid(pfn)) {
		out_append("romap %s va=%016lx pa=%016lx pfn=%lx no_struct_page (VM_IO/MMIO)\n",
			   tag, va, pa, pfn);
		return;
	}
	pg = compound_head(pfn_to_page(pfn));
	ref = atomic_read(&pg->_refcount);
	mapc = atomic_read(&pg->_mapcount);
	fl = READ_ONCE(pg->flags);
	mp = READ_ONCE(pg->mapping);
	out_append("romap %s va=%016lx pa=%016lx pfn=%06lx ref=%d mapcount=%d flags=%016lx mapping=%px class=%s%s\n",
		   tag, va, pa, pfn, ref, mapc, fl, mp,
		   PageAnon(pg) ? "anon" : (mp ? "file" : "none"),
		   PageCompound(pg) ? " compound" : "");
}

/* D14/H6: full task_pt_regs of a live task (kernel-stack read, racy values) */
static void ptregs_report(struct task_struct *t, int pid)
{
	struct pt_regs *r = task_pt_regs(t);
	int i;

	out_append("romap ptregs pid=%d comm=%s state=%u sp=%016llx sp_page=%016llx pc=%016llx pstate=%016llx\n",
		   pid, t->comm, t->__state, r->sp, r->sp & PAGE_MASK,
		   r->pc, r->pstate);
	for (i = 0; i < 31; i += 4)
		out_append("romap ptregs x%02d=%016llx x%02d=%016llx x%02d=%016llx x%02d=%016llx\n",
			   i, r->regs[i], i + 1, r->regs[i + 1],
			   i + 2, r->regs[i + 2], i + 3, r->regs[i + 3]);
}

static struct task_struct *get_task_by_pid(int pid)
{
	struct pid *p;
	struct task_struct *t;

	p = find_get_pid(pid);
	if (!p)
		return NULL;
	t = get_pid_task(p, PIDTYPE_PID);
	put_pid(p);
	return t;
}

static ssize_t rm_write(struct file *f, const char __user *ubuf, size_t len,
			loff_t *off)
{
	char kbuf[80];
	int pid = 0, ptregs_mode = 0;
	unsigned long va = 0, refva = 0;
	struct task_struct *t;
	struct mm_struct *mm;

	if (len == 0 || len >= sizeof(kbuf))
		return -EINVAL;
	if (copy_from_user(kbuf, ubuf, len))
		return -EFAULT;
	kbuf[len] = '\0';

	if (strncmp(kbuf, "ptregs", 6) == 0) {
		if (sscanf(kbuf, "ptregs %d", &pid) != 1)
			return -EINVAL;
		ptregs_mode = 1;
	} else {
		int rc = sscanf(kbuf, "%d %lx %lx", &pid, &va, &refva);

		if (rc < 2)
			return -EINVAL;
	}

	/* only ordinary user tasks; canonical user VA only */
	if (pid <= 1 || (va >> 48) != 0 || (refva >> 48) != 0)
		return -EINVAL;

	if (!capable(CAP_SYS_PTRACE)) {
		mutex_lock(&g_lock);
		out_reset();
		out_append("romap err=-EPERM (need CAP_SYS_PTRACE)\n");
		mutex_unlock(&g_lock);
		return -EPERM;
	}

	t = get_task_by_pid(pid);
	if (!t) {
		mutex_lock(&g_lock);
		out_reset();
		out_append("romap err=-ESRCH pid=%d\n", pid);
		mutex_unlock(&g_lock);
		return len;
	}

	mutex_lock(&g_lock);
	out_reset();

	if (ptregs_mode) {
		ptregs_report(t, pid);
	} else {
		mm = get_task_mm(t);
		if (!mm) {
			out_append("romap err=-EINVAL pid=%d no user mm (kernel thread?)\n",
				   pid);
		} else {
			/* default reference page = page of the task's saved
			 * user sp (same-batch D12 control) */
			if (!refva)
				refva = task_pt_regs(t)->sp & PAGE_MASK;
			mmap_read_lock(mm);
			if (!refva)
				out_append("romap ref unavailable (sp_page=0)\n");
			page_report(mm, "tgt", va);
			if (refva)
				page_report(mm, "ref", refva);
			mmap_read_unlock(mm);
			mmput(mm);
		}
	}

	mutex_unlock(&g_lock);
	/* mirror result to dmesg so a lost `cat` cannot lose the evidence */
	pr_info("%s", g_out);
	put_task_struct(t);
	return len;
}

static ssize_t rm_read(struct file *f, char __user *ubuf, size_t len,
		       loff_t *off)
{
	size_t n;
	int rc;

	if (*off > 0 || !g_len)
		return 0;
	mutex_lock(&g_lock);
	n = min(len, g_len);
	rc = copy_to_user(ubuf, g_out, n);
	mutex_unlock(&g_lock);
	if (rc)
		return -EFAULT;
	*off += n;
	return n;
}

static const struct proc_ops rm_ops = {
	.proc_read	= rm_read,
	.proc_write	= rm_write,
};

static int __init romap_init(void)
{
	pe = proc_create("romap", 0644, NULL, &rm_ops);
	if (!pe)
		return -ENOMEM;
	out_reset();
	out_append("romap: no query yet (echo \"<pid> <hexva> [refva]\" or \"ptregs <pid>\" > /proc/romap)\n");
	pr_info("romap: loaded (D12 page five-tuple + D14/H6 ptregs; read-only)\n");
	return 0;
}

static void __exit romap_exit(void)
{
	if (pe)
		proc_remove(pe);
	pr_info("romap: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(romap_init);
module_exit(romap_exit);

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
