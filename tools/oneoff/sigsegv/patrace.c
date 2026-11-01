// SPDX-License-Identifier: GPL-2.0
// patrace.ko -- read-only VA->PA tracer for LG6151M (5.15.134 aarch64).
//
//   echo "<pid> <hexva>" > /proc/patrace
//   cat /proc/patrace     ->  "pid=.. va=0x.. pa=0x.. err=.. peek=<16B hex>"
//
// Purpose: fill the gap left by CONFIG_PROC_PAGE_MONITOR=n (no /proc/*/pagemap).
// Read-only: walks the target task's page tables under mmap_read_lock; never
// writes kernel state. Invalid input -> error code, never panic.
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/pid.h>
#include <linux/mm.h>
#include <linux/pgtable.h>
#include <linux/io.h>
#include <linux/version.h>
#include <asm/pgtable.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("patrace: read-only user VA -> PA page-table walker");
MODULE_AUTHOR("chr431");

static struct proc_dir_entry *pe;

static int g_pid, g_err;
static unsigned long g_va, g_pa;
static unsigned char g_peek[16];
static int g_peek_ok;

/* returns 0 on success and fills *pa */
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

static ssize_t pt_write(struct file *f, const char __user *ubuf, size_t len, loff_t *off)
{
    char kbuf[64];
    int pid = 0;
    unsigned long va = 0, pa = 0;
    struct pid *p;
    struct task_struct *t;
    struct mm_struct *mm;
    int ret;

    g_err = 0; g_pa = 0; g_peek_ok = 0; g_pid = 0; g_va = 0;

    if (len == 0 || len >= sizeof(kbuf))
        return -EINVAL;
    if (copy_from_user(kbuf, ubuf, len))
        return -EFAULT;
    kbuf[len] = 0;
    if (sscanf(kbuf, "%d %lx", &pid, &va) != 2)
        return -EINVAL;
    /* only ordinary user tasks: no init, no kernel threads, sane VA */
    if (pid <= 1 || (va >> 48) != 0)
        return -EINVAL;

    g_pid = pid; g_va = va;

    p = find_get_pid(pid);
    if (!p) { g_err = -ESRCH; return len; }
    t = get_pid_task(p, PIDTYPE_PID);
    put_pid(p);
    if (!t) { g_err = -ESRCH; return len; }
    mm = get_task_mm(t);
    put_task_struct(t);
    if (!mm) { g_err = -EINVAL; return len; }

    mmap_read_lock(mm);
    ret = walk_va(mm, va, &pa);
    mmap_read_unlock(mm);
    mmput(mm);

    if (ret) { g_err = ret; return len; }

    g_pa = pa;
    if ((pa >> 32) == 0) {   /* linear-mapped RAM only (device RAM < 4 GiB) */
        const unsigned char *k = (const unsigned char *)__va(pa & PAGE_MASK);
        memcpy(g_peek, k, sizeof(g_peek));
        g_peek_ok = 1;
    }
    return len;
}

static ssize_t pt_read(struct file *f, char __user *ubuf, size_t len, loff_t *off)
{
    char out[256];
    int n, i, pos = 0;

    if (*off > 0)
        return 0;
    n = scnprintf(out, sizeof(out), "pid=%d va=0x%lx pa=0x%lx err=%d peek_ok=%d peek=",
                  g_pid, g_va, g_pa, g_err, g_peek_ok);
    for (i = 0; i < 16 && n + 3 < (int)sizeof(out); i++)
        n += scnprintf(out + n, sizeof(out) - n, "%02x", g_peek_ok ? g_peek[i] : 0);
    n += scnprintf(out + n, sizeof(out) - n, "\n");
    if (n > (int)len)
        n = len;
    if (copy_to_user(ubuf, out, n))
        return -EFAULT;
    *off += n;
    return n;
}

static const struct proc_ops pt_ops = {
    .proc_read  = pt_read,
    .proc_write = pt_write,
};

static int __init patrace_init(void)
{
    pe = proc_create("patrace", 0644, NULL, &pt_ops);
    if (!pe)
        return -ENOMEM;
    pr_info("patrace: loaded (echo \"<pid> <hexva>\" > /proc/patrace)\n");
    return 0;
}

static void __exit patrace_exit(void)
{
    if (pe)
        proc_remove(pe);
    pr_info("patrace: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(patrace_init);
module_exit(patrace_exit);

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
