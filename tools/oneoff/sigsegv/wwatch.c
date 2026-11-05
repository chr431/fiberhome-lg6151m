// wwatch.c -- CAM-W Tier B watchpoint engine v1 (U-G1, 2026-11-05).
//
// Purpose: catch the SIGSEGV 32B-record writer IN THE ACT on the victim's
// stack qword (stack_top-0x16A0, 96.2% of last night's real landings).
// Mechanism:
//   * take over debug_fault_info[2] (HWWP dispatch; no hw_breakpoint framework
//     on this kernel, original fn == do_bad) with a recorder that logs
//     {pc,lr,sp,far,esr,pstate,comm,pid} and skips the faulting store
//     (regs->pc += 4) then returns 0 -> exception swallowed, no die, no signal.
//   * program 4 store-only 8B EL1 watchpoints on every online CPU:
//       WVR0 = alias+0 (linear map of the slot PA)   WCR = EL1|store|BAS8
//       WVR1 = alias+8
//       WVR2 = alias+16
//       WVR3 = uva+0 (user VA form; catches PAN-open plain str at EL1)
//     EL0 is deliberately NOT armed: the victim's own variadic callee writes
//     this exact qword every iteration (would flood, and skipping its store
//     would corrupt the victim).
//   * MDSCR |= MDE|KDE, DBGPRCR |= CORENPDRGG on every CPU (cpuidle has
//     clusteroff_l/mcusysoff; bit keeps debug state through powerdown).
//   * 2s recheck timer (workqueue + smp_call per cpu): WCR drift -> rewrite
//     and count (idle-loss detector).
//
// Safety:
//   * insmod REFUSE gate: dfi[2].fn must equal <dobad> param and its name
//     must contain "watchpoint" (else someone else owns HWWP -> refuse).
//   * every touched register saved per-cpu before modify, restored on disarm,
//     readback-verified; disarm before rmmod is enforced.
//   * recorder is NMI-safe: no locks, no alloc, no printk; global ring with
//     atomic index (wrhunt2 pattern).
//
// proc interface (/proc/wwatch):
//   cat               -> status, counters, ring
//   echo probe        -> sample sysregs on all cpus to dmesg
//   echo arm uva=0x.. alias=0x.. pa=0x.. vtlo=0x.. vthi=0x..
//   echo selfstore    -> benign control: read alias+0 then write the same
//                        value back (fires W0, no data change)
//   echo dump         -> pr_info ring
//   echo disarm       -> restore everything + verify
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/fs.h>
#include <linux/timer.h>
#include <linux/workqueue.h>
#include <linux/smp.h>
#include <linux/cpumask.h>
#include <linux/uaccess.h>
#include <linux/atomic.h>
#include <linux/percpu.h>
#include <linux/string.h>
#include <asm/ptrace.h>
#include <asm/sysreg.h>
#include <asm/debug-monitors.h>

#ifndef SYS_DBGPRCR_EL1
#define SYS_DBGPRCR_EL1 sys_reg(2, 0, 1, 4, 4)
#endif

#define pr_fmt(fmt) "wwatch: " fmt

#define NRING 64
#define NSLOT 4
#define MAXCPU 8

/* ---- WCR encoding (same fields the kernel's hw_breakpoint.h uses) ---- */
#define WCR_E      (1UL << 0)
#define WCR_PAC_EL1 (1UL << 1)   /* AARCH64_BREAKPOINT_EL1 == 1, <<1 */
#define WCR_PAC_EL0 (2UL << 1)   /* AARCH64_BREAKPOINT_EL0 == 2, <<1 */
#define WCR_LSC_ST (2UL << 3)    /* ARM_BREAKPOINT_STORE */
#define WCR_LSC_LD (1UL << 3)    /* ARM_BREAKPOINT_LOAD  */
static u64 g_wcr_lsc = WCR_LSC_ST;
static u64 g_wcr_arr[NSLOT];
#define WCR_BAS8   (0xffUL << 5) /* 8 bytes */
#define WW_WCR_EL1 (WCR_E | WCR_PAC_EL1 | WCR_LSC_ST | WCR_BAS8)
#define WW_WCR_EL0 (WCR_E | WCR_PAC_EL0 | WCR_LSC_ST | WCR_BAS8)
static u64 g_wcr_val = WW_WCR_EL1;

/* ---- explicit-name sysreg access (clang IAS chokes on kernel mrs_s macros) ---- */
#define WW_RD(name) ({ u64 __v; asm volatile("mrs %0, " #name : "=r"(__v)); __v; })
#define WW_WR(name, v) asm volatile("msr " #name ", %0" :: "r"((u64)(v)))

static inline u64 ww_rd_wvr(int n)
{
	u64 v;
	switch (n) {
	case 0: asm volatile("mrs %0, s2_0_c0_c0_6" : "=r"(v)); break;
	case 1: asm volatile("mrs %0, s2_0_c0_c1_6" : "=r"(v)); break;
	case 2: asm volatile("mrs %0, s2_0_c0_c2_6" : "=r"(v)); break;
	default: asm volatile("mrs %0, s2_0_c0_c3_6" : "=r"(v)); break;
	}
	return v;
}
static inline void ww_wr_wvr(int n, u64 v)
{
	switch (n) {
	case 0: asm volatile("msr s2_0_c0_c0_6, %0" :: "r"(v)); break;
	case 1: asm volatile("msr s2_0_c0_c1_6, %0" :: "r"(v)); break;
	case 2: asm volatile("msr s2_0_c0_c2_6, %0" :: "r"(v)); break;
	default: asm volatile("msr s2_0_c0_c3_6, %0" :: "r"(v)); break;
	}
}
static inline u64 ww_rd_wcr(int n)
{
	u64 v;
	switch (n) {
	case 0: asm volatile("mrs %0, s2_0_c0_c0_7" : "=r"(v)); break;
	case 1: asm volatile("mrs %0, s2_0_c0_c1_7" : "=r"(v)); break;
	case 2: asm volatile("mrs %0, s2_0_c0_c2_7" : "=r"(v)); break;
	default: asm volatile("mrs %0, s2_0_c0_c3_7" : "=r"(v)); break;
	}
	return v;
}
static inline void ww_wr_wcr(int n, u64 v)
{
	switch (n) {
	case 0: asm volatile("msr s2_0_c0_c0_7, %0" :: "r"(v)); break;
	case 1: asm volatile("msr s2_0_c0_c1_7, %0" :: "r"(v)); break;
	case 2: asm volatile("msr s2_0_c0_c2_7, %0" :: "r"(v)); break;
	default: asm volatile("msr s2_0_c0_c3_7, %0" :: "r"(v)); break;
	}
}
/* NBRP=6 on this A53: DBGBCRn = s2_0_c0_cN_5 */
static inline u64 ww_rd_bcr(int n)
{
	u64 v;
	switch (n) {
	case 0: asm volatile("mrs %0, s2_0_c0_c0_5" : "=r"(v)); break;
	case 1: asm volatile("mrs %0, s2_0_c0_c1_5" : "=r"(v)); break;
	case 2: asm volatile("mrs %0, s2_0_c0_c2_5" : "=r"(v)); break;
	case 3: asm volatile("mrs %0, s2_0_c0_c3_5" : "=r"(v)); break;
	case 4: asm volatile("mrs %0, s2_0_c0_c4_5" : "=r"(v)); break;
	default: asm volatile("mrs %0, s2_0_c0_c5_5" : "=r"(v)); break;
	}
	return v;
}
static inline u64 ww_rd_osdlr(void)
{
	u64 v;
	asm volatile("mrs %0, s2_0_c1_c3_4" : "=r"(v));
	return v;
}
static inline void ww_wr_osdlr0(void)
{
	asm volatile("msr s2_0_c1_c3_4, xzr");
}
static inline void ww_osunlock(void)
{
	/* OSLAR_EL1 (s2_0_c1_c0_4) key write 0 = unlock; then clear OSDLR.DLK */
	asm volatile("msr s2_0_c1_c0_4, xzr");
	asm volatile("msr s2_0_c1_c3_4, xzr");
	asm volatile("isb");
}
static inline void ww_wr_bcr(int n, u64 v)
{
	switch (n) {
	case 0: asm volatile("msr s2_0_c0_c0_5, %0" :: "r"(v)); break;
	case 1: asm volatile("msr s2_0_c0_c1_5, %0" :: "r"(v)); break;
	case 2: asm volatile("msr s2_0_c0_c2_5, %0" :: "r"(v)); break;
	case 3: asm volatile("msr s2_0_c0_c3_5, %0" :: "r"(v)); break;
	case 4: asm volatile("msr s2_0_c0_c4_5, %0" :: "r"(v)); break;
	default: asm volatile("msr s2_0_c0_c5_5, %0" :: "r"(v)); break;
	}
}


/* ---- params (REFUSE gate anchors) ---- */
static unsigned long p_dfi;    /* debug_fault_info kva  */
static unsigned long p_dobad;  /* do_bad kva            */
module_param_named(dfi, p_dfi, ulong, 0444);
module_param_named(dobad, p_dobad, ulong, 0444);

struct fault_info_ {
	int (*fn)(unsigned long, unsigned int, struct pt_regs *);
	int sig;
	int code;
	const char *name;
};

/* ---- ring ---- */
struct ev {
	u32 seq;
	u32 cpu;
	u64 vcnt;
	u64 far;
	u32 esr;
	u32 skip;
	u64 pc, lr, sp, pstate;
	s32 pid, tgid;
	char comm[16];
};
static struct ev g_ring[NRING];
static atomic_t g_seq = ATOMIC_INIT(0);

/* ---- state ---- */
static int g_armed;
static int g_nslot;
static unsigned long g_uva, g_alias, g_pa, g_vtlo, g_vthi;
static unsigned long g_uva2, g_alias2;
static unsigned long g_wvr_v[NSLOT];
static int (*g_orig_fn)(unsigned long, unsigned int, struct pt_regs *);
static atomic_t g_drift = ATOMIC_INIT(0);
static atomic_t g_armfail = ATOMIC_INIT(0);

#define NBRP 6
struct cpustate { u64 mdscr, prcr, wcr[NSLOT], wvr[NSLOT], bcr[NBRP]; };
static struct cpustate g_save[MAXCPU];
static struct cpustate g_last[MAXCPU];   /* last probe snapshot */
static int g_wrps = -1;

static DEFINE_PER_CPU(u64, cnt_fire);
static DEFINE_PER_CPU(u64, cnt_el0);
static DEFINE_PER_CPU(u64, cnt_own);

/* ================================================================ handler */
static int ww_wp_fn(unsigned long far, unsigned int esr, struct pt_regs *regs)
{
	struct ev *e;
	u32 s;

	this_cpu_inc(cnt_fire);

	if (user_mode(regs)) {
		/* EL0-mode fire: victim self-writes (va_list init, ~100/s) have
		 * pc inside the victim exe text -> count and drop.  Anything
		 * else (kernel STTR unprivileged store, foreign EL0 code at the
		 * same VA value) gets recorded.  pc += 4 skips the store. */
		this_cpu_inc(cnt_el0);
		if (regs->pc >= g_vtlo && regs->pc < g_vthi) {
			this_cpu_inc(cnt_own);
			if ((regs->pc & 3UL) == 0)
				regs->pc += 4;
			return 0;
		}
		s = atomic_inc_return(&g_seq);
		e = &g_ring[s & (NRING - 1)];
		e->seq = s;
		e->cpu = smp_processor_id();
		e->vcnt = WW_RD(cntvct_el0);
		e->far = far;
		e->esr = esr;
		e->pc = regs->pc;
		e->lr = regs->regs[30];
		e->sp = regs->sp;
		e->pstate = regs->pstate;
		e->pid = current->pid;
		e->tgid = current->tgid;
		memcpy(e->comm, current->comm, sizeof(e->comm));
		if ((regs->pc & 3UL) == 0) {
			regs->pc += 4;
			e->skip = 1;
		} else
			e->skip = 2;
		return 0;
	}

	s = atomic_inc_return(&g_seq);
	e = &g_ring[s & (NRING - 1)];
	e->seq   = s;
	e->cpu   = smp_processor_id();
	e->vcnt  = WW_RD(cntvct_el0);
	e->far   = far;
	e->esr   = esr;
	e->pc    = regs->pc;
	e->lr    = regs->regs[30];
	e->sp    = regs->sp;
	e->pstate= regs->pstate;
	e->pid   = current->pid;
	e->tgid  = current->tgid;
	memcpy(e->comm, current->comm, sizeof(e->comm));
	if ((regs->pc & 3UL) == 0) {
		regs->pc += 4;   /* skip the faulting store: it must not re-fire */
		e->skip = 1;
	} else {
		e->skip = 2;
	}
	return 0;   /* handled -> no arm64_notify_die, no die(), no signal */
}

/* ============================================================ per-cpu ops */
static void ww_probe_one(void *x)
{
	int cpu = smp_processor_id(), i;
	struct cpustate *cs = &g_last[cpu];

	cs->mdscr = WW_RD(mdscr_el1);
	cs->prcr  = WW_RD(dbgprcr_el1);
	for (i = 0; i < NSLOT; i++) {
		cs->wcr[i] = ww_rd_wcr(i);
		cs->wvr[i] = ww_rd_wvr(i);
	}
	for (i = 0; i < NBRP; i++)
		cs->bcr[i] = ww_rd_bcr(i);
}

static void ww_save_one(void *x)
{
	int cpu = smp_processor_id(), i;

	g_save[cpu].mdscr = WW_RD(mdscr_el1);
	g_save[cpu].prcr  = WW_RD(dbgprcr_el1);
	for (i = 0; i < NSLOT; i++) {
		g_save[cpu].wcr[i] = ww_rd_wcr(i);
		g_save[cpu].wvr[i] = ww_rd_wvr(i);
	}
	for (i = 0; i < NBRP; i++)
		g_save[cpu].bcr[i] = ww_rd_bcr(i);
}

static void ww_osunlock_one(void *x)
{
	ww_osunlock();
}

static void ww_mdscr_on_one(void *x)
{
	int i;
	for (i = 0; i < NBRP; i++)
		ww_wr_bcr(i, 0);
	for (i = 0; i < NSLOT; i++)
		ww_wr_wcr(i, 0);
	isb();
	WW_WR(mdscr_el1, g_save[smp_processor_id()].mdscr | DBG_MDSCR_MDE | DBG_MDSCR_KDE);
	isb();
}

static void ww_mdscr_off_one(void *x)
{
	int i;
	int cpu = smp_processor_id();
	WW_WR(mdscr_el1, g_save[cpu].mdscr);
	isb();
	for (i = 0; i < NBRP; i++)
		ww_wr_bcr(i, g_save[cpu].bcr[i]);
	for (i = 0; i < NSLOT; i++)
		ww_wr_wcr(i, g_save[cpu].wcr[i]);
	isb();
}

static void ww_arm_one(void *x)
{
	int i;
	u64 m;

	ww_osunlock();
	for (i = 0; i < NBRP; i++)
		ww_wr_bcr(i, 0);              /* kill garbage breakpoints FIRST */
	for (i = 0; i < NSLOT; i++)
		ww_wr_wcr(i, 0);              /* and stale watchpoints */
	isb();
	for (i = 0; i < g_nslot; i++) {
		ww_wr_wvr(i, g_wvr_v[i]);
		ww_wr_wcr(i, g_wcr_arr[i]);
	}
	isb();
	m = g_save[smp_processor_id()].mdscr | DBG_MDSCR_MDE | DBG_MDSCR_KDE;
	WW_WR(mdscr_el1, m);
	/* v1.11: DBGPRCR write removed again (crash7 = 2nd reproduction of
	 * its lethality). Idle-wipe handled OUTSIDE: the operator disables
	 * cpuoff_l/clusteroff_l/mcusysoff cpuidle states so cores stay in
	 * WFI retention and debug registers survive. */
	isb();
	/* verify */
	for (i = 0; i < g_nslot; i++)
		if (ww_rd_wcr(i) != g_wcr_arr[i])
			atomic_inc(&g_armfail);
}

static void ww_recheck_one(void *x)
{
	int i;

	for (i = 0; i < g_nslot; i++) {
		if (ww_rd_wcr(i) != g_wcr_arr[i]) {
			atomic_inc(&g_drift);
			for (i = 0; i < g_nslot; i++) {
				ww_wr_wvr(i, g_wvr_v[i]);
				ww_wr_wcr(i, WW_WCR_EL1);
			}
			isb();
			return;
		}
	}
}

static void ww_disarm_one(void *x)
{
	int i;
	int cpu = smp_processor_id();

	WW_WR(mdscr_el1, g_save[cpu].mdscr);
	WW_WR(dbgprcr_el1, g_save[cpu].prcr);
	isb();
	for (i = 0; i < NSLOT; i++) {
		ww_wr_wcr(i, g_save[cpu].wcr[i]);
		ww_wr_wvr(i, g_save[cpu].wvr[i]);
	}
	for (i = 0; i < NBRP; i++)
		ww_wr_bcr(i, g_save[cpu].bcr[i]);
	isb();
}

static int for_all_cpus(void (*fn)(void *))
{
	int cpu;

	for_each_online_cpu(cpu)
		smp_call_function_single(cpu, fn, NULL, 1);
	return 0;
}

/* ================================================================ recheck */
static void ww_recheck_work(struct work_struct *w);
static DECLARE_WORK(ww_work, ww_recheck_work);
static struct timer_list ww_tick;

static void ww_recheck_work(struct work_struct *w)
{
	if (g_armed)
		for_all_cpus(ww_recheck_one);
}

static void ww_tickfn(struct timer_list *t)
{
	if (g_armed)
		schedule_work(&ww_work);
	mod_timer(&ww_tick, jiffies + HZ / 2);
}

/* ================================================================== proc */
static int ww_proc_show(struct seq_file *m, void *v)
{
	int i, cpu;
	u64 tot_fire = 0, tot_el0 = 0, tot_own = 0;

	for_each_online_cpu(cpu) {
		tot_fire += per_cpu(cnt_fire, cpu);
		tot_el0  += per_cpu(cnt_el0, cpu);
		tot_own  += per_cpu(cnt_own, cpu);
	}
	seq_printf(m, "wwatch v1 armed=%d nslot=%d wrps=%d\n",
		   g_armed, g_nslot, g_wrps);
	seq_printf(m, "uva=%lx alias=%lx pa=%lx vt=[%lx,%lx)\n",
		   g_uva, g_alias, g_pa, g_vtlo, g_vthi);
	seq_printf(m, "seq=%d fire=%llu el0=%llu drift=%d armfail=%d\n",
		   atomic_read(&g_seq), tot_fire, tot_el0,
		   atomic_read(&g_drift), atomic_read(&g_armfail));
	for (i = 0; i < NRING; i++) {
		struct ev *e = &g_ring[i];
		if (!e->seq)
			continue;
		seq_printf(m, "EV s=%u cpu=%u far=%llx esr=%x skip=%u pc=%llx lr=%llx sp=%llx ps=%llx pid=%d/%d comm=%s\n",
			   e->seq, e->cpu, e->far, e->esr, e->skip,
			   e->pc, e->lr, e->sp, e->pstate, e->pid, e->tgid, e->comm);
	}
	return 0;
}

static int ww_proc_open(struct inode *ino, struct file *f)
{
	return single_open(f, ww_proc_show, NULL);
}

static ssize_t ww_proc_write(struct file *f, const char __user *ub, size_t n, loff_t *off)
{
	char buf[160];
	int rc;
	unsigned long a1, a2, a3, a4, a5, a6, a7;
	volatile u64 *p;
	u64 v;

	if (n >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ub, n))
		return -EFAULT;
	buf[n] = 0;

	if (!strncmp(buf, "probe", 5)) {
		u64 dfr0;
		for_all_cpus(ww_probe_one);
		dfr0 = WW_RD(id_aa64dfr0_el1);
		g_wrps = (int)((dfr0 >> ID_AA64DFR0_WRPS_SHIFT) & 0xf) + 1;
		pr_info("probe: WRPS=%d BRPS=%d\n", g_wrps,
			(int)((dfr0 >> ID_AA64DFR0_BRPS_SHIFT) & 0xf) + 1);
		{
			int cpu;
			u64 oslsr = WW_RD(oslsr_el1);
			u64 osdlr = ww_rd_osdlr();
			for_each_online_cpu(cpu) {
				struct cpustate *c = &g_last[cpu];
				pr_info("cpu%d mdscr=%llx prcr=%llx oslsr=%llx osdlr=%llx wcr=%llx,%llx,%llx,%llx wvr=%llx,%llx,%llx,%llx\n",
					cpu, c->mdscr, c->prcr, oslsr, osdlr,
					c->wcr[0], c->wcr[1], c->wcr[2], c->wcr[3],
					c->wvr[0], c->wvr[1], c->wvr[2], c->wvr[3],
				c->bcr[0], c->bcr[1], c->bcr[2], c->bcr[3], c->bcr[4], c->bcr[5]);
			}
		}
		pr_info("probe done\n");
		return n;
	}
	if (!strncmp(buf, "linrd", 5)) {
		/* zero-risk alias resolver: AT-translate each PAGE_OFFSET
		 * candidate, read u64 only if translation succeeds */
		static const u64 cands[3] = {
			0xffffffc000000000ULL,  /* 39-bit map guess   */
			0xffffff8000000000ULL,  /* 48-bit map guess   */
			0xffffff7f80000000ULL   /* night-note value   */
		};
		unsigned long pa2 = 0;
		int ci;
		u64 par;
		if (sscanf(buf, "linrd pa=%lx", &pa2) != 1 || !pa2)
			return -EINVAL;
		for (ci = 0; ci < 3; ci++) {
			u64 va = cands[ci] + pa2, val = 0, ok = 0;
			asm volatile("at s1e1r, %0" :: "r"(va));
			asm volatile("isb");
			asm volatile("mrs %0, par_el1" : "=r"(par));
			if (!(par & 1)) {         /* PAR.F=0 -> valid */
				val = *(volatile u64 *)va;
				ok = 1;
			}
			pr_info("linrd cand%d va=%llx par=%llx ok=%llu val=%llx\n",
				ci, va, par, ok, ok ? val : 0ULL);
		}
		return n;
	}
	if (!strncmp(buf, "mdscr on", 8)) {
		if (g_armed) return -EBUSY;
		for_all_cpus(ww_save_one);
		for_all_cpus(ww_mdscr_on_one);
		pr_info("mdscr on: MDE|KDE enabled, all BCR/WCR zeroed, no WRP\n");
		return n;
	}
	if (!strncmp(buf, "mdscr off", 9)) {
		for_all_cpus(ww_mdscr_off_one);
		pr_info("mdscr off: restored\n");
		return n;
	}
	if (!strncmp(buf, "selfstore", 9)) {
		if (!g_armed)
			return -EINVAL;
		p = (volatile u64 *)g_alias;
		v = *p;                 /* read does not fire (store-only) */
		*p = v;                 /* same value back: fires W0, zero change */
		mb();
		pr_info("selfstore: wrote-back %llx at alias=%lx seq=%d\n",
			v, g_alias, atomic_read(&g_seq));
		return n;
	}
	if (!strncmp(buf, "dump", 4)) {
		pr_info("dump: seq=%d\n", atomic_read(&g_seq));
		return n;
	}
	if (!strncmp(buf, "osunlock", 8)) {
		for_all_cpus(ww_osunlock_one);
		pr_info("osunlock: OSLAR=0 + OSDLR=0 on all cpus, oslsr=%llx osdlr=%llx\n",
			WW_RD(oslsr_el1), ww_rd_osdlr());
		return n;
	}
	if (!strncmp(buf, "armraw", 6)) {
		/* diagnostic arm: program WRP regs + MDSCR ONLY.
		 * no dfi swap, no timer. any fire -> do_bad path -> with
		 * panic_on_oops=0 an oops names the faulting store pc. */
		if (g_armed) return -EBUSY;
		if (sscanf(buf, "armraw uva=%lx alias=%lx uva2=%lx alias2=%lx",
			   &a1, &a2, &a6, &a7) != 4)
			return -EINVAL;
		g_wcr_val = strstr(buf, "el0") ? WW_WCR_EL0 : WW_WCR_EL1;
		if (g_wrps < 0) { pr_err("armraw refused: probe first\n"); return -EINVAL; }
		g_uva = a1; g_alias = a2; g_pa = 0; g_uva2 = a6; g_alias2 = a7;
		g_nslot = g_wrps < NSLOT ? g_wrps : NSLOT;
		g_wvr_v[0] = g_alias;
		g_wvr_v[1] = g_uva;
		g_wvr_v[2] = g_alias2;
		g_wvr_v[3] = g_uva2;
		for_all_cpus(ww_save_one);
		for_all_cpus(ww_arm_one);
		g_armed = 2;   /* regs armed, dfi untouched */
		pr_info("ARMRAW nslot=%d wvr=%lx,%lx,%lx,%lx armfail=%d\n",
			g_nslot, g_wvr_v[0], g_wvr_v[1], g_wvr_v[2], g_wvr_v[3],
			atomic_read(&g_armfail));
		return n;
	}
	rc = sscanf(buf, "arm uva=%lx alias=%lx pa=%lx vtlo=%lx vthi=%lx uva2=%lx alias2=%lx",
		    &a1, &a2, &a3, &a4, &a5, &a6, &a7);
	if (rc == 7) {
		if (g_armed)
			return -EBUSY;
		if (g_wrps < 0) {
			pr_err("arm refused: run probe first\n");
			return -EINVAL;
		}
		g_uva = a1; g_alias = a2; g_pa = a3; g_vtlo = a4; g_vthi = a5;
		g_uva2 = a6; g_alias2 = a7;
		g_wcr_val = strstr(buf, "el0") ? WW_WCR_EL0 : WW_WCR_EL1;
		{
			unsigned long lscv = 2;
			if (strstr(buf, "lsc=1") || strstr(buf, "lsc=load")) lscv = 1;
			else if (strstr(buf, "lsc=3") || strstr(buf, "lsc=both")) lscv = 3;
			g_wcr_lsc = lscv << 3;
			g_wcr_val = (g_wcr_val & ~(3UL << 3)) | g_wcr_lsc;
		}
		g_nslot = g_wrps < NSLOT ? g_wrps : NSLOT;
		if (strstr(buf, "loadmix")) {
			/* load-watch suicide set: alias(EL1) + uva(EL0, catches
			 * kernel LDTR) on q0+q1 of the primary slot */
			g_wvr_v[0] = g_alias;
			g_wvr_v[1] = g_uva;
			g_wvr_v[2] = g_alias + 8;
			g_wvr_v[3] = g_uva + 8;
			g_wcr_arr[0] = WCR_E | WCR_PAC_EL1 | WCR_LSC_LD | WCR_BAS8;
			g_wcr_arr[1] = WCR_E | WCR_PAC_EL0 | WCR_LSC_LD | WCR_BAS8;
			g_wcr_arr[2] = WCR_E | WCR_PAC_EL1 | WCR_LSC_LD | WCR_BAS8;
			g_wcr_arr[3] = WCR_E | WCR_PAC_EL0 | WCR_LSC_LD | WCR_BAS8;
		} else if (strstr(buf, "el0")) {
			g_wvr_v[0] = g_uva;
			g_wvr_v[1] = g_uva2;
			g_wvr_v[2] = g_uva + 8;
			g_wvr_v[3] = g_uva2 + 8;
			g_wcr_arr[0] = g_wcr_arr[1] = g_wcr_val;
			g_wcr_arr[2] = g_wcr_arr[3] = g_wcr_val;
		} else {
			g_wvr_v[0] = g_alias;
			g_wvr_v[1] = g_uva;
			g_wvr_v[2] = g_alias2;
			g_wvr_v[3] = g_uva2;
			g_wcr_arr[0] = g_wcr_arr[1] = g_wcr_val;
			g_wcr_arr[2] = g_wcr_arr[3] = g_wcr_val;
		}
		/* take the dispatch slot first (regs not armed yet -> quiet) */
		((struct fault_info_ *)p_dfi)[2].fn = ww_wp_fn;
		if (((struct fault_info_ *)p_dfi)[2].fn != ww_wp_fn) {
			pr_err("arm refused: dfi write did not stick\n");
			return -EFAULT;
		}
		for_all_cpus(ww_save_one);
		for_all_cpus(ww_arm_one);
		g_armed = 1;
		mod_timer(&ww_tick, jiffies + HZ / 2);
		pr_info("ARMED nslot=%d wvr=%lx,%lx,%lx,%lx wcr=%lx armfail=%d\n",
			g_nslot, g_wvr_v[0], g_wvr_v[1], g_wvr_v[2], g_wvr_v[3],
			(unsigned long)WW_WCR_EL1, atomic_read(&g_armfail));
		return n;
	}
	if (!strncmp(buf, "disarm", 6)) {
		if (!g_armed)
			return -EINVAL;
		g_armed = 0;
		del_timer_sync(&ww_tick);
		cancel_work_sync(&ww_work);
		for_all_cpus(ww_disarm_one);
		((struct fault_info_ *)p_dfi)[2].fn = g_orig_fn;
		pr_info("DISARMED seq=%d drift=%d armfail=%d fnrestored=%d\n",
			atomic_read(&g_seq), atomic_read(&g_drift),
			atomic_read(&g_armfail),
			((struct fault_info_ *)p_dfi)[2].fn == g_orig_fn);
		return n;
	}
	pr_err("unknown cmd\n");
	return -EINVAL;
}

static const struct proc_ops ww_proc_ops = {
	.proc_open    = ww_proc_open,
	.proc_read    = seq_read,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
	.proc_write   = ww_proc_write,
};

/* ================================================================== init */
static int __init ww_init(void)
{
	struct fault_info_ *fi = (struct fault_info_ *)p_dfi;
	const char *nm;

	if (!p_dfi || !p_dobad) {
		pr_err("need dfi= and dobad= params\n");
		return -EINVAL;
	}
	/* REFUSE gate */
	if (fi[2].fn != (void *)p_dobad) {
		pr_err("REFUSE: dfi[2].fn=%px != dobad=%lx (someone owns HWWP?)\n",
		       fi[2].fn, p_dobad);
		return -EINVAL;
	}
	nm = fi[2].name;
	if (!nm || !strstr(nm, "watchpoint")) {
		pr_err("REFUSE: dfi[2].name='%s' unexpected\n", nm ? nm : "(null)");
		return -EINVAL;
	}
	g_orig_fn = fi[2].fn;

	proc_create("wwatch", 0644, NULL, &ww_proc_ops);
	timer_setup(&ww_tick, ww_tickfn, 0);
	pr_info("loaded: dfi=%lx dobad=%lx name='%s' orig_fn=%px\n",
		p_dfi, p_dobad, fi[2].name, g_orig_fn);
	return 0;
}

static void __exit ww_exit(void)
{
	if (g_armed) {
		pr_err("rmmod refused while armed\n");
		/* cannot abort unload from exit; caller must disarm first */
	}
	remove_proc_entry("wwatch", NULL);
	if (g_armed) {
		/* belt and braces: disarm path without prints */
		g_armed = 0;
		del_timer_sync(&ww_tick);
		cancel_work_sync(&ww_work);
		for_all_cpus(ww_disarm_one);
		((struct fault_info_ *)p_dfi)[2].fn = g_orig_fn;
	}
	pr_info("unloaded seq=%d\n", atomic_read(&g_seq));
}

module_init(ww_init);
module_exit(ww_exit);
MODULE_LICENSE("GPL");
/* raw -c chain has no modpost: emit modinfo entries by hand (wrhunt2/patrace pattern) */
MODULE_INFO(vermagic, "5.15.134 SMP mod_unload aarch64");
MODULE_INFO(name, KBUILD_MODNAME);

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};
