// SPDX-License-Identifier: GPL-2.0
// tuphook.ko v1.5 -- narrow entry hook for mtk_warp's wifi_tx_tuple_add /
// wifi_rx_tuple_add on LG6151M (5.15.134 aarch64, vendor mtk_warp.ko).
//
// v1.5 (D19): the two entry points are recorded exactly as in v1.4 (x0..x3),
// and the entry's skb (x2) is dereferenced IN THE CAPTURE PATH through
// copy_from_kernel_nofault, so every record also carries
//     skb->len, ip_hdr(skb)->saddr, skb->protocol, cntvct_el0
// The goal is to answer which fill call carries the 32B record family
// {len in 321/1600/1601/4416/4480, ip = flow endpoint}.
//
// ===================== why entry patching looks like this =====================
// Exported-API survey of the device kernel (linux-5.15.134, .config == device
// IKCONFIG) decided the whole construction:
//   - CONFIG_KPROBES is NOT set    -> no kprobe address resolver.
//   - CONFIG_FUNCTION_TRACER is not set -> no ftrace.
//   - CONFIG_PERF_EVENTS is not set -> no hw breakpoint path.
//   - register_kernel_break_hook / aarch64_insn_patch_text / module_alloc /
//     __set_fixmap / get_vm_area / bpf_jit_binary_alloc are NOT exported.
//     => a BRK-based hook is impossible from a module, and the trampoline
//        can only live inside our own module image (the 128MB module region
//        is the only executable VA space guaranteed within B range of
//        mtk_warp: vmap() lands at/above MODULES_END == VMALLOC_START, i.e. up
//        to 128MB+ away, out of the B range).
// Chosen primitive: a single 4-byte `B` replaces `paciasp` at each entry
// (both entries start with paciasp -- verified in the vendor disassembly and
// re-verified at load). The trampoline re-executes the displaced instruction
// and branches back to entry+4, so the original prologue runs unchanged.
// 4-byte aligned stores are single-copy atomic on arm64: a CPU that already
// fetched the old instruction runs the untouched prologue; one that fetches
// the new one enters the trampoline. No intermediate state exists.
//
// Writing module text (CONFIG_STRICT_MODULE_RWX=y makes both mtk_warp's and
// our own .text RO+X) needs a writable window. The kernel pgd is read from
// TTBR1_EL1, then pgd->p4d->pud->pmd->pte is walked with plain (inline)
// helpers. The PTE is flipped writable, the words are written with all CPUs
// parked in stop_machine, every CPU runs its local I-cache maintenance, and
// the PTE is restored. pmd_leaf is refused: module text is PTE-mapped, and a
// PMD leaf would otherwise trip BUG_ON inside apply_to_page_range.
//
// Trampoline (v1.5, straight line + ONE call to our own probe, 80-byte stack
// frame, scratch = x9/x10/x11/x12/x13/x16/x17, arguments x0..x3 untouched):
//   adr  x16, pool          ; pool = {percpu_offset_P, pad} inside our .text
//   ldr  x17, [x16]         ; P = alloc_percpu pointer VALUE (full 64-bit)
//   mrs  x9, tpidr_el1|el2  ; per-cpu base of THIS cpu (patched at init:
//                           ; VHE kernels keep it in tpidr_el2)
//   add  x9, x17, x9        ; x9 = struct tup_ring (this cpu)
//   ldr  x17, [x9, #0x4000] ; head = (idx << 1) | nested_guard
//   tbnz x17, #0, nested    ; recursion guard: nested entry skips recording
//   add  x17, x17, #3       ; idx+1 AND set guard bit
//   str  x17, [x9, #0x4000] ; guard is set BEFORE the probe call
//   sub  sp, sp, #80        ; frame below the caller's SP (restored before
//   stp  x0, x1, [sp]       ; paciasp: the PAC modifier must be the entry SP)
//   stp  x2, x3, [sp, #16]
//   stp  x8, x30, [sp, #32]
//   stp  x19, x20, [sp, #48]
//   str  x9, [sp, #64]
//   mov  x0, x2             ; skb
//   mov  x1, #0|1           ; is_rx
//   add  x2, x9, #0x4008    ; &ring->scratch (per-cpu probe output)
//   bl   tuphook_probe      ; nofault deref, cannot oops, cannot sleep
//   ldp  x0, x1, [sp]       ; restore the original arguments and LR
//   ldp  x2, x3, [sp, #16]
//   ldp  x8, x30, [sp, #32]
//   ldr  x9, [sp, #64]
//   ldr  x17, [x9, #0x4000]
//   ubfx x10, x17, #1, #8   ; idx = head >> 1 (256-entry ring, overwrite)
//   add  x10, x9, x10, lsl #6
//   stp  x0, x1, [x10]
//   stp  x2, x3, [x10, #16]
//   ldp  x11, x12, [x9, #0x4008]  ; len_ip, meta
//   ldp  x13, x14, [x9, #0x4018]  ; ts, proto
//   stp  x11, x12, [x10, #32]
//   stp  x13, x14, [x10, #48]
//   bic  x17, x17, #1
//   str  x17, [x9, #0x4000]
//   ldp  x19, x20, [sp, #48]
//   add  sp, sp, #80
//   paciasp                 ; displaced instruction, executed verbatim
//   b    entry+4            ; patched at init
// nested:
//   paciasp
//   b    entry+4            ; patched at init
// IRQ nesting is the only re-entry source (PREEMPT_NONE, no migration); the
// guard makes a nested call bypass recording (and bypass the probe) while
// still running the original function normally. Only the guard owner writes,
// so a torn record is impossible.
//
// ===================== skb offsets (D19 static verification) =====================
// The device kernel Image (kernel_Image.bin + kallsyms.pkl) was disassembled
// at four independent anchors; all four agree with the layout compiled here:
//   skb_pull        ldr  w2,[x0,#0x70]      -> len
//   skb_copy_bits   ldr  w0,[x0,#0x70]      -> len
//                   ldr  w21,[x24,#0x74]    -> data_len
//                   ldr  x1,[x24,#0xc8]     -> data
//                   ldr  x0,[x24,#0xc0]     -> head
//                   ldr  w1,[x24,#0xbc]     -> end
//   skb_release_data ldr x20,[x19,#0xc0]    -> head
//   ip_rcv_core     ldrh w4,[x19,#0xb4]     -> network_header
//                   ldr  x3,[x19,#0xc0]     -> head
//                   ldr  w2,[x3,x4]         -> ip_hdr(skb)
//   eth_type_trans  strh w3,[x0,#0xb6]      -> mac_header
//   __dev_queue_xmit ldrh w0,[x19,#0xb2]    -> transport_header
// The BUILD_BUG_ONs in tuphook_init() pin these numbers at compile time: a
// mismatched .config/compiler fails the build instead of producing a .ko that
// would read the wrong words. Runtime sanity is additionally enforced by the
// probe (IP version nibble, network_header bound, protocol report).
//
// Safety posture vs ipanic/mrdump (S0 lesson: any oops = forced reboot even
// with panic_on_oops=0): every address is validated before use.
//   warp_wlan_tx is an EXPORTED mtk_warp symbol, so the loader resolves it
//   (and pins mtk_warp while we are loaded); base = addr - 0x970; both
//   entries must decode as paciasp AND sprint_symbol() must name them
//   wifi_tx_tuple_add / wifi_rx_tuple_add, otherwise init fails cleanly.
// Runtime reads use copy_from_kernel_nofault (extable-fixed, cannot oops).
// The trampoline only touches its own per-cpu ring.
//
// Module params:
//   dryrun=1     POSITIVE CONTROL: locate + kallsyms reverse-lookup + ops
//                chain report + offset report only; NOT ONE BYTE is patched.
//   maxread=N    records printed per CPU by /proc/tuphook (default 64, cap 256)
//
// See REVIEW-tuphook.md for the per-function audit, export evidence and the
// on-device validation sequence.
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
#include <linux/sched/task.h>
#include <linux/pid.h>
#include <linux/atomic.h>
#include <linux/stop_machine.h>
#include <linux/percpu.h>
#include <linux/cpumask.h>
#include <linux/smp.h>
#include <linux/delay.h>
#include <linux/string.h>
#include <linux/stdarg.h>
#include <linux/kallsyms.h>
#include <linux/types.h>
#include <linux/skbuff.h>
#include <linux/ip.h>
#include <asm/pgtable.h>
#include <asm/memory.h>
#include <asm/barrier.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("tuphook: narrow entry recorder + skb deref for mtk_warp wifi_tx/rx_tuple_add (v1.5)");
MODULE_AUTHOR("chr431");

/* ---- vendor mtk_warp.ko .text offsets (objdump of the shipped module) ---- */
#define TUP_OFF_WLAN_TX	0x970	/* exported; base anchor */
#define TUP_OFF_TX	0x7330	/* wifi_tx_tuple_add, size 0x3f4 */
#define TUP_OFF_RX	0x7268	/* wifi_rx_tuple_add, size 0xc8 */
#define TUP_OFF_SUB0	0x0000	/* bind_get: adrp+add at +4/+8 -> .bss slot */
#define TUP_OFF_ENTRY	0x1718	/* warp_entry_get_by_idx: adrp+add at +0/+8 */
#define INS_PACIASP	0xd503233fu

#define TUP_OFF_OPS	0x700	/* ctx+0x700 = ops (seen in both tuple fns) */
#define TUP_OFF_TXCB	0x18	/* ops+0x18 tx fill callback */
#define TUP_OFF_RXCB	0x50	/* ops+0x50 rx fill callback */
#define TUP_OFF_UPDCB	0x60	/* ops+0x60 wo-rxcnt sink (wifi_chip_update) */
#define TUP_BIND_KEY	0x10	/* bind entry: key pointer */
#define TUP_ENTRY_SZ	0xb1a8	/* warp entry stride (warp_entry_get_by_idx objdump) */

/* ---- struct sk_buff field offsets, pinned by BUILD_BUG_ON in init ----
 * (D19: verified against the device kernel Image, see header comment) */
#define SKB_OFF_PROTO	0xb0	/* __be16 protocol */
#define SKB_OFF_NH	0xb4	/* u16 network_header */
#define SKB_OFF_HEAD	0xc0	/* unsigned char *head */
#define SKB_OFF_LEN	0x70	/* unsigned int len */
#define IPH_OFF_SADDR	12	/* struct iphdr.saddr */

#define TUP_NREC	256
#define TUP_RECSZ	64
#define TUP_HEAD_OFF	(TUP_NREC * TUP_RECSZ)	/* 0x4000 */
#define TUP_NM		256	/* sprint_symbol buffer (KSYM_NAME_LEN + mod) */

/* probe meta bits */
#define TUP_M_RX	0x0001
#define TUP_M_LEN_OK	0x0002
#define TUP_M_HEAD_BAD	0x0004
#define TUP_M_NH_BAD	0x0008
#define TUP_M_IPV4_BAD	0x0010
#define TUP_M_IP_OK	0x0020
#define TUP_M_NOSKB	0x0040
#define TUP_M_LEN_BAD	0x0080
#define TUP_M_IP_BAD	0x0100

static int dryrun;
module_param(dryrun, int, 0444);
MODULE_PARM_DESC(dryrun, "1 = locate + kallsyms + ops + offset report only, patch nothing");
static int maxread = 64;
module_param(maxread, int, 0444);
MODULE_PARM_DESC(maxread, "records printed per cpu by /proc/tuphook (default 64, cap 256)");

struct tup_rec {
	u64 x0;		/* ctx (bind+8) */
	u64 x1;		/* band/if index (+ garbage high bits) */
	u64 x2;		/* skb */
	u64 x3;		/* tx: flags; rx: undefined */
	u64 len_ip;	/* [31:0] skb->len, [63:32] ip_hdr(skb)->saddr */
	u64 meta;	/* TUP_M_* bits */
	u64 ts;		/* cntvct_el0 at capture */
	u64 proto;	/* [15:0] skb->protocol (host order value read) */
};

/* per-cpu probe output; written by tuphook_probe() and copied into the ring
 * by the trampoline (kept separate so a reader never sees a half record
 * beyond what v1.4 already allowed: the counter is bumped before the probe) */
struct tup_probe_out {
	u64 len_ip;
	u64 meta;
	u64 ts;
	u64 proto;
};

struct tup_ring {
	struct tup_rec recs[TUP_NREC];
	u64 head;	/* (idx<<1) | nested_guard */
	struct tup_probe_out scratch;	/* 0x4008 */
};

static struct tup_ring __percpu *rings;

/* ---- trampoline: 160B per entry, straight line + one call, patch words
 *      marked with labels (no index arithmetic in the install path) ---- */
asm(
".pushsection .text\n"
".balign 4096\n"
".globl tuphook_tramp_tx\n"
"tuphook_tramp_tx:\n"
"	adr	x16, tuphook_pool\n"
"	ldr	x17, [x16]\n"
".globl tuphook_mrs_tx\n"
"tuphook_mrs_tx:\n"
"	mrs	x9, tpidr_el1\n"
"	add	x9, x17, x9\n"
"	ldr	x17, [x9, #0x4000]\n"
"	tbnz	x17, #0, 2f\n"
"	add	x17, x17, #3\n"
"	str	x17, [x9, #0x4000]\n"
"	sub	sp, sp, #80\n"
"	stp	x0, x1, [sp]\n"
"	stp	x2, x3, [sp, #16]\n"
"	stp	x8, x30, [sp, #32]\n"
"	stp	x19, x20, [sp, #48]\n"
"	str	x9, [sp, #64]\n"
"	mov	x0, x2\n"
"	mov	x1, #0\n"
"	mov	x2, #0x4008\n"
"	add	x2, x9, x2\n"
"	bl	tuphook_probe\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x3, [sp, #16]\n"
"	ldp	x8, x30, [sp, #32]\n"
"	ldr	x9, [sp, #64]\n"
"	ldr	x17, [x9, #0x4000]\n"
"	ubfx	x10, x17, #1, #8\n"
"	add	x10, x9, x10, lsl #6\n"
"	stp	x0, x1, [x10]\n"
"	stp	x2, x3, [x10, #16]\n"
"	mov	x15, #0x4008\n"
"	add	x15, x9, x15\n"
"	ldp	x11, x12, [x15]\n"
"	ldp	x13, x14, [x15, #16]\n"
"	stp	x11, x12, [x10, #32]\n"
"	stp	x13, x14, [x10, #48]\n"
"	bic	x17, x17, #1\n"
"	str	x17, [x9, #0x4000]\n"
"	ldp	x19, x20, [sp, #48]\n"
"	add	sp, sp, #80\n"
"	.inst	0xd503233f\n"		/* paciasp (displaced instruction) */
".globl tuphook_back_tx\n"
"tuphook_back_tx:\n"
"	b	.\n"			/* patched at init: b entry+4 */
"2:\n"
"	.inst	0xd503233f\n"
".globl tuphook_backn_tx\n"
"tuphook_backn_tx:\n"
"	b	.\n"			/* patched at init: b entry+4 */
".globl tuphook_tramp_rx\n"
"tuphook_tramp_rx:\n"
"	adr	x16, tuphook_pool\n"
"	ldr	x17, [x16]\n"
".globl tuphook_mrs_rx\n"
"tuphook_mrs_rx:\n"
"	mrs	x9, tpidr_el1\n"
"	add	x9, x17, x9\n"
"	ldr	x17, [x9, #0x4000]\n"
"	tbnz	x17, #0, 2f\n"
"	add	x17, x17, #3\n"
"	str	x17, [x9, #0x4000]\n"
"	sub	sp, sp, #80\n"
"	stp	x0, x1, [sp]\n"
"	stp	x2, x3, [sp, #16]\n"
"	stp	x8, x30, [sp, #32]\n"
"	stp	x19, x20, [sp, #48]\n"
"	str	x9, [sp, #64]\n"
"	mov	x0, x2\n"
"	mov	x1, #1\n"
"	mov	x2, #0x4008\n"
"	add	x2, x9, x2\n"
"	bl	tuphook_probe\n"
"	ldp	x0, x1, [sp]\n"
"	ldp	x2, x3, [sp, #16]\n"
"	ldp	x8, x30, [sp, #32]\n"
"	ldr	x9, [sp, #64]\n"
"	ldr	x17, [x9, #0x4000]\n"
"	ubfx	x10, x17, #1, #8\n"
"	add	x10, x9, x10, lsl #6\n"
"	stp	x0, x1, [x10]\n"
"	stp	x2, x3, [x10, #16]\n"
"	mov	x15, #0x4008\n"
"	add	x15, x9, x15\n"
"	ldp	x11, x12, [x15]\n"
"	ldp	x13, x14, [x15, #16]\n"
"	stp	x11, x12, [x10, #32]\n"
"	stp	x13, x14, [x10, #48]\n"
"	bic	x17, x17, #1\n"
"	str	x17, [x9, #0x4000]\n"
"	ldp	x19, x20, [sp, #48]\n"
"	add	sp, sp, #80\n"
"	.inst	0xd503233f\n"
".globl tuphook_back_rx\n"
"tuphook_back_rx:\n"
"	b	.\n"
"2:\n"
"	.inst	0xd503233f\n"
".globl tuphook_backn_rx\n"
"tuphook_backn_rx:\n"
"	b	.\n"
".balign 16\n"
".globl tuphook_pool\n"
"tuphook_pool:\n"
"	.quad 0\n"			/* [0] = percpu offset P, patched at init */
"	.quad 0\n"
".popsection\n"
);

extern char tuphook_tramp_tx[];
extern char tuphook_tramp_rx[];
extern char tuphook_mrs_tx[];
extern char tuphook_mrs_rx[];
extern char tuphook_back_tx[];
extern char tuphook_back_rx[];
extern char tuphook_backn_tx[];
extern char tuphook_backn_rx[];
extern unsigned long tuphook_pool[];

/* exported by mtk_warp.ko; the loader resolves it cross-module and pins the
 * vendor module for as long as we are loaded */
extern void warp_wlan_tx(void);

static bool installed;
static unsigned long g_base, g_tx, g_rx;
static u32 g_bent_tx, g_bent_rx;
static char g_txname[TUP_NM], g_rxname[TUP_NM];
static char g_opsline[1024];

/* ------------------------------------------------------------------ */
/* skb probe: called from the trampoline BEFORE the original prologue  */
/* ------------------------------------------------------------------ */
/* Every dereference goes through copy_from_kernel_nofault(): the load and
 * its fixup live in vmlinux (mm/maccess.c -> __get_kernel_nofault -> "ldr"
 * with a .fixup entry), so a wild/freed/unmapped skb pointer can only make
 * the read fail, never oops. No sleeping, no allocation, safe in softirq. */
__attribute__((used))
noinline void tuphook_probe(u64 skb, u64 is_rx, struct tup_probe_out *out)
{
	u64 meta = is_rx ? TUP_M_RX : 0;
	u64 lp = 0, ts = 0, proto = 0xffff;
	u32 len = 0, ip = 0;
	u16 nh = 0, pr = 0;
	u64 head = 0;
	u8 ver = 0;

	asm volatile("mrs %0, cntvct_el0" : "=r"(ts));
	out->len_ip = 0;
	out->meta = 0;
	out->ts = ts;
	out->proto = proto;
	if (!skb) {
		out->meta = meta | TUP_M_NOSKB;
		return;
	}
	if (copy_from_kernel_nofault(&len, (const void *)(skb + SKB_OFF_LEN), 4)) {
		meta |= TUP_M_LEN_BAD;
	} else {
		lp = len;
		meta |= TUP_M_LEN_OK;
	}
	if (!copy_from_kernel_nofault(&pr, (const void *)(skb + SKB_OFF_PROTO), 2))
		proto = pr;
	if (copy_from_kernel_nofault(&head, (const void *)(skb + SKB_OFF_HEAD), 8) ||
	    !head) {
		out->len_ip = lp;
		out->proto = proto;
		out->meta = meta | TUP_M_HEAD_BAD;
		return;
	}
	if (copy_from_kernel_nofault(&nh, (const void *)(skb + SKB_OFF_NH), 2) ||
	    nh > 0x4000) {
		out->len_ip = lp;
		out->proto = proto;
		out->meta = meta | TUP_M_NH_BAD;
		return;
	}
	if (copy_from_kernel_nofault(&ver, (const void *)(head + nh), 1) ||
	    (ver >> 4) != 4) {
		out->len_ip = lp;
		out->proto = proto;
		out->meta = meta | TUP_M_IPV4_BAD;
		return;
	}
	if (copy_from_kernel_nofault(&ip, (const void *)(head + nh + IPH_OFF_SADDR), 4)) {
		out->len_ip = lp;
		out->proto = proto;
		out->meta = meta | TUP_M_IP_BAD;
		return;
	}
	lp |= (u64)ip << 32;
	out->len_ip = lp;
	out->proto = proto;
	out->meta = meta | TUP_M_IP_OK;
}

/* ------------------------------------------------------------------ */
/* page-table window for writing module text                           */
/* ------------------------------------------------------------------ */
struct pte_flip {
	pte_t *ptep;
	pte_t val;
	unsigned long page;
};

/* Kernel (TTBR1) top-level page table, i.e. init_mm.pgd == swapper_pg_dir.
 *
 * Reading TTBR1_EL1 is exact, needs no symbol, and is VA_BITS independent:
 * TTBR1_EL1[47:12] is the physical base (ASID lives in [63:48] and is 0 for
 * the kernel pgd).  __va() maps it into the linear map (memstart_addr is
 * exported). */
static int tup_get_kernel_pgd(pgd_t **out)
{
	unsigned long t, pa;
	pgd_t *pgd;

	asm volatile("mrs %0, ttbr1_el1" : "=r"(t));
	pa = t & 0x0000fffffffff000UL;		/* BADDR, page aligned */
	if (!pa)
		return -ENODEV;
	pgd = (pgd_t *)__va(pa);
	/* structural sanity: the kernel pgd lives in the linear map, i.e.
	 * between PAGE_OFFSET and the vmalloc region, for any VA_BITS */
	if (((unsigned long)pgd & (PAGE_SIZE - 1)) ||
	    (unsigned long)pgd < PAGE_OFFSET ||
	    (unsigned long)pgd >= VMALLOC_START)
		return -EINVAL;
	*out = pgd;
	return 0;
}

static int tup_walk_pte(unsigned long va, pte_t **out)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;

	if (tup_get_kernel_pgd(&pgd))
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
	if (pmd_leaf(READ_ONCE(*pmd)))	/* never fold WRITE over 2MB */
		return -EINVAL;
	pte = pte_offset_kernel(pmd, va);
	if (!pte_present(READ_ONCE(*pte)))
		return -ENOENT;
	*out = pte;
	return 0;
}

static atomic_t flip_cpus;

static int tup_flip_cb(void *arg)
{
	struct pte_flip *f = arg;

	if (atomic_inc_return(&flip_cpus) == 1) {
		WRITE_ONCE(*f->ptep, f->val);
		dsb(ish);
		atomic_inc(&flip_cpus);	/* master finished (kernel pattern) */
	} else {
		while (atomic_read(&flip_cpus) <= num_online_cpus())
			cpu_relax();
	}
	/* every CPU drops its own TLB entry for the page (kernel ASID space) */
	asm volatile("dsb ishst\n"
		     "tlbi vaale1is, %0\n"
		     "dsb ish\n"
		     "isb" :: "r"(f->page >> 12) : "memory");
	return 0;
}

/* swap the PTE value (write bit on/off) with all CPUs synchronized */
static int tup_set_pte(pte_t *ptep, pte_t val, unsigned long page)
{
	struct pte_flip f = {
		.ptep = ptep,
		.val = val,
		.page = page,
	};

	atomic_set(&flip_cpus, 0);
	return stop_machine(tup_flip_cb, &f, NULL);
}

/* ------------------------------------------------------------------ */
/* instruction patch primitive                                         */
/* ------------------------------------------------------------------ */
struct patch_item {
	void *addr;
	u32 insn;
};

struct patch_req {
	struct patch_item items[8];
	int n;
};

static atomic_t patch_cpus;

static int tup_patch_cb(void *arg)
{
	struct patch_req *r = arg;
	int i;

	if (atomic_inc_return(&patch_cpus) == 1) {
		for (i = 0; i < r->n; i++)
			WRITE_ONCE(*(u32 *)r->items[i].addr, r->items[i].insn);
		dsb(ish);
		atomic_inc(&patch_cpus);	/* release secondaries */
	} else {
		while (atomic_read(&patch_cpus) <= num_online_cpus())
			cpu_relax();
	}
	/* local I-cache maintenance for every patched word on every CPU */
	for (i = 0; i < r->n; i++)
		asm volatile("dc cvau, %0\n"
			     "dsb ish\n"
			     "ic ivau, %0\n"
			     "dsb ish\n"
			     "isb" :: "r"(r->items[i].addr) : "memory");
	return 0;
}

/* patch up to 8 words on one page; leaves the PTE exactly as found */
static int tup_patch_words(unsigned long page, struct patch_item *items, int n)
{
	pte_t *ptep, orig;
	struct patch_req r;
	int rc, i;

	if (n < 1 || n > 8)
		return -EINVAL;
	for (i = 0; i < n; i++)
		if (((unsigned long)items[i].addr & PAGE_MASK) != page)
			return -EINVAL;
	rc = tup_walk_pte(page, &ptep);
	if (rc)
		return rc;
	orig = READ_ONCE(*ptep);
	if (!pte_write(orig)) {
		rc = tup_set_pte(ptep, pte_mkwrite(orig), page);
		if (rc)
			return rc;
	}
	memset(&r, 0, sizeof(r));
	r.n = n;
	for (i = 0; i < n; i++)
		r.items[i] = items[i];
	atomic_set(&patch_cpus, 0);
	rc = stop_machine(tup_patch_cb, &r, NULL);
	if (!pte_write(orig))
		tup_set_pte(ptep, orig, page);	/* restore RO whatever happened */
	return rc;
}

/* ------------------------------------------------------------------ */
/* resolution + positive control                                       */
/* ------------------------------------------------------------------ */
static int tup_resolve(void)
{
	unsigned long anchor = (unsigned long)&warp_wlan_tx;
	u32 itx, irx;

	g_base = anchor - TUP_OFF_WLAN_TX;
	g_tx = g_base + TUP_OFF_TX;
	g_rx = g_base + TUP_OFF_RX;
	itx = READ_ONCE(*(u32 *)g_tx);
	irx = READ_ONCE(*(u32 *)g_rx);
	if (itx != INS_PACIASP || irx != INS_PACIASP) {
		pr_err("tuphook: entry insn mismatch tx=%08x rx=%08x (want %08x)\n",
		       itx, irx, INS_PACIASP);
		return -EINVAL;
	}
	sprint_symbol(g_txname, g_tx);
	sprint_symbol(g_rxname, g_rx);
	if (!strstr(g_txname, "wifi_tx_tuple_add")) {
		pr_err("tuphook: kallsyms says tx entry is '%s'\n", g_txname);
		return -EINVAL;
	}
	if (!strstr(g_rxname, "wifi_rx_tuple_add")) {
		pr_err("tuphook: kallsyms says rx entry is '%s'\n", g_rxname);
		return -EINVAL;
	}
	return 0;
}

/* decode ADRP + ADD imm pair -> absolute kernel VA */
static int tup_decode_adr_pair(unsigned long pc, u32 adrp, u32 add,
			       unsigned long *out)
{
	s64 imm;
	u64 page, off = 0;

	if ((adrp & 0x9f000000u) != 0x90000000u)
		return -EINVAL;
	imm = ((s64)((adrp >> 5) & 0x7ffff) << 2) | ((adrp >> 29) & 3);
	if (imm & (1 << 20))
		imm -= (1 << 21);
	page = (pc & ~0xfffUL) + ((u64)imm << 12);
	if ((add & 0x7f800000u) == 0x11000000u) {
		u32 imm12 = (add >> 10) & 0xfff;

		off = (add & (1u << 22)) ? ((u64)imm12 << 12) : imm12;
	}
	*out = (unsigned long)(page + off);
	return 0;
}

static int tup_rd64(unsigned long addr, void *v)
{
	return copy_from_kernel_nofault(v, (const void *)addr, 8);
}

static int tup_rd32(unsigned long addr, void *v)
{
	return copy_from_kernel_nofault(v, (const void *)addr, 4);
}

/* One .bss slot derivation, cross-checked from two independent call sites.
 * sub_0 (bind_get) and warp_entry_get_by_idx both load the bind array from
 * the same slot: count at [+0], array pointer at [+0x10]. */
static int tup_find_bind_slot(unsigned long *slot_out)
{
	unsigned long a = 0, b = 0;

	if (tup_decode_adr_pair(g_base + TUP_OFF_SUB0 + 4,
				READ_ONCE(*(u32 *)(g_base + TUP_OFF_SUB0 + 4)),
				READ_ONCE(*(u32 *)(g_base + TUP_OFF_SUB0 + 8)),
				&a))
		return -EINVAL;
	if (tup_decode_adr_pair(g_base + TUP_OFF_ENTRY,
				READ_ONCE(*(u32 *)(g_base + TUP_OFF_ENTRY)),
				READ_ONCE(*(u32 *)(g_base + TUP_OFF_ENTRY + 8)),
				&b))
		return -EINVAL;
	if (a != b) {
		pr_warn("tuphook: bind slot disagreement %lx vs %lx\n", a, b);
		return -EINVAL;
	}
	*slot_out = a;
	return 0;
}

static void tup_report_bind_ops(void)
{
	unsigned long slot, entry, ctx, ops = 0, txcb = 0, rxcb = 0, updcb = 0;
	u64 cnt = 0, arr = 0, key = 0;
	char b1[TUP_NM] = "?", b2[TUP_NM] = "?", b3[TUP_NM] = "?";

	g_opsline[0] = '\0';
	if (tup_find_bind_slot(&slot)) {
		snprintf(g_opsline, sizeof(g_opsline),
			 "bind: slot decode FAILED\n");
		return;
	}
	if (tup_rd32(slot, (u32 *)&cnt) || tup_rd64(slot + 0x10, &arr) ||
	    !arr || !cnt || cnt > 4) {
		snprintf(g_opsline, sizeof(g_opsline),
			 "bind: slot=%016lx count=%llu arr=%016llx unusable\n",
			 slot, cnt, arr);
		return;
	}
	entry = (unsigned long)arr;	/* entry 0 */
	/* walk entries 0..cnt-1: entry0 may be unbound while later entries hold
	 * the live binds (observed on-device 2026-11-02: count=3, entry0 key=0) */
	{
		u64 k;
		u32 i, idx = 0;

		if (tup_rd64(entry + TUP_BIND_KEY, &key) )
			key = 0;
		for (i = 0; !key && i < cnt && i < 4; i++) {
			entry = (unsigned long)arr + (unsigned long)i * TUP_ENTRY_SZ;
			if (tup_rd64(entry + TUP_BIND_KEY, &k) || !k)
				continue;
			key = k;
			idx = i;
		}
		if (!key) {
			snprintf(g_opsline, sizeof(g_opsline),
				 "bind: count=%llu arr=%016llx no live bind in %llu entries\n",
				 cnt, arr, cnt);
			return;
		}
		if (idx)
			pr_info("tuphook: live bind at entry%u (entry0 unbound)\n", idx);
	}
	ctx = entry + 8;
	if (tup_rd64(ctx + TUP_OFF_OPS, &ops) || !ops) {
		snprintf(g_opsline, sizeof(g_opsline),
			 "bind: count=%llu entry=%016lx key=%016llx ops unreadable\n",
			 cnt, entry, key);
		return;
	}
	tup_rd64(ops + TUP_OFF_TXCB, &txcb);
	tup_rd64(ops + TUP_OFF_RXCB, &rxcb);
	tup_rd64(ops + TUP_OFF_UPDCB, &updcb);
	if (txcb)
		sprint_symbol(b1, (unsigned long)txcb);
	if (rxcb)
		sprint_symbol(b2, (unsigned long)rxcb);
	if (updcb)
		sprint_symbol(b3, (unsigned long)updcb);
	snprintf(g_opsline, sizeof(g_opsline),
		 "bind: count=%llu arr=%016llx entry=%016llx key=%016llx ctx=%016llx\n"
		 "ops:  ctx+0x700=%016lx\n"
		 "cb:   tx_fill(ops+0x18)=%s\n"
		 "cb:   rx_fill(ops+0x50)=%s\n"
		 "cb:   wo_rxcnt(ops+0x60)=%s\n",
		 cnt, arr, entry, key, ctx, ops, b1, b2, b3);
}

/* ------------------------------------------------------------------ */
/* install / remove                                                    */
/* ------------------------------------------------------------------ */
static u32 tup_mkb(s64 delta)
{
	return 0x14000000u | (((u64)delta >> 2) & 0x03ffffffu);
}

/* decode a `b` word back to its absolute target from its own site: the
 * self-check below is what stands between a delta sign error and an
 * instruction abort at a wild address (v1.3 did exactly that on-device) */
static unsigned long tup_b_target(unsigned long site, u32 insn)
{
	s64 d = (s64)(insn & 0x03ffffffu);

	if (d & 0x02000000)
		d -= 0x04000000;
	return (unsigned long)((s64)site + d * 4);
}

/* The trampoline's per-cpu base register.  arm64 keeps the per-cpu offset in
 * tpidr_el1 normally, but with VHE (HCR_EL2.E2H=1) the kernel's
 * set_my_cpu_offset()/__my_cpu_offset() are ALTERNATIVE-patched to tpidr_el2
 * and tpidr_el1 is never written (reads 0).  Both mrs words are verified
 * against the kernel's own per_cpu_ptr() at install time; only the matching
 * one is patched in. */
#define INS_MRS_TPIDR_EL1	0xd538d089u	/* mrs x9, tpidr_el1 */
#define INS_MRS_TPIDR_EL2	0xd53cd049u	/* mrs x9, tpidr_el2 */

static unsigned long tup_my_cpu_off_el1(void)
{
	unsigned long off;

	asm volatile("mrs %0, tpidr_el1" : "=r"(off));
	return off;
}

static unsigned long tup_my_cpu_off_el2(void)
{
	unsigned long off;

	asm volatile("mrs %0, tpidr_el2" : "=r"(off));
	return off;
}

static u64 tup_id_aa64mmfr1(void)
{
	u64 v;

	asm volatile("mrs %0, id_aa64mmfr1_el1" : "=r"(v));
	return v;
}

static int tup_install(void)
{
	unsigned long P = (unsigned long)rings;
	unsigned long off, p_ptr;
	u32 mrs_insn;
	unsigned long tpage = (unsigned long)tuphook_tramp_tx & PAGE_MASK;
	unsigned long epage = g_tx & PAGE_MASK;
	s64 dtx, drx, dback_tx, dback_rx, dbackn_tx, dbackn_rx;
	struct patch_item items[8];
	u64 *pool = (u64 *)tuphook_pool;
	int rc;

	/* per_cpu_offset() is unsigned long and the dynamic percpu region sits
	 * above 4G on this kernel (observed 0x3d79487000), so the pool word is
	 * written as two 32-bit halves and never truncated.
	 * The trampoline's P + tpidr_elX must equal the kernel's own
	 * per_cpu_ptr() result for this cpu; the register that matches is the
	 * one patched in.  Any mismatch refuses install with zero patches. */
	p_ptr = (unsigned long)per_cpu_ptr(rings, raw_smp_processor_id());
	off = tup_my_cpu_off_el1();
	if (P + off == p_ptr) {
		mrs_insn = INS_MRS_TPIDR_EL1;
	} else if (((tup_id_aa64mmfr1() >> 4) & 0xf) != 0) {
		/* Hardware implements VHE, and the kernel is demonstrably not
		 * using tpidr_el1 => it runs with E2H=1 and keeps the per-cpu
		 * base in tpidr_el2 (only readable at EL1 when E2H=1). */
		off = tup_my_cpu_off_el2();
		if (P + off != p_ptr) {
			pr_err("tuphook: percpu identity mismatch (VHE) P=%lx off2=%lx sum=%lx per_cpu_ptr=%lx\n",
			       P, off, P + off, p_ptr);
			return -EINVAL;
		}
		mrs_insn = INS_MRS_TPIDR_EL2;
	} else {
		pr_err("tuphook: percpu identity mismatch P=%lx off1=%lx sum=%lx per_cpu_ptr=%lx, no VHE\n",
		       P, off, P + off, p_ptr);
		return -EINVAL;
	}
	pr_info("tuphook: percpu P=%lx off=%lx reg=%s (64-bit pool, identity ok)\n",
		P, off, mrs_insn == INS_MRS_TPIDR_EL2 ? "tpidr_el2/VHE" : "tpidr_el1");
	/* both trampolines and the pool must share one page for one window */
	if (((unsigned long)tuphook_tramp_rx & PAGE_MASK) != tpage ||
	    ((unsigned long)pool & PAGE_MASK) != tpage) {
		pr_err("tuphook: trampoline block straddles a page\n");
		return -EINVAL;
	}
	/* both entries must share one page for a single writable window */
	if (((g_rx) & PAGE_MASK) != epage) {
		pr_err("tuphook: entries not on one page -- refusing\n");
		return -EINVAL;
	}
	/* the entry branch is written AT g_tx and must land ON the trampoline,
	 * so its delta is (trampoline - entry).  v1.0-v1.3 reused the
	 * trampoline-site delta here (entry - trampoline_site), which sent the
	 * first real rx call ~15.8 MB below mtk_warp into the unmapped module
	 * region. */
	dtx = (s64)(unsigned long)tuphook_tramp_tx - (s64)g_tx;
	drx = (s64)(unsigned long)tuphook_tramp_rx - (s64)g_rx;
	dback_tx = (s64)(g_tx + 4) - (s64)tuphook_back_tx;
	dback_rx = (s64)(g_rx + 4) - (s64)tuphook_back_rx;
	dbackn_tx = (s64)(g_tx + 4) - (s64)tuphook_backn_tx;
	dbackn_rx = (s64)(g_rx + 4) - (s64)tuphook_backn_rx;
	if (dtx < -(1 << 27) || dtx >= (1 << 27) ||
	    drx < -(1 << 27) || drx >= (1 << 27) ||
	    dback_tx < -(1 << 27) || dback_tx >= (1 << 27) ||
	    dback_rx < -(1 << 27) || dback_rx >= (1 << 27) ||
	    dbackn_tx < -(1 << 27) || dbackn_tx >= (1 << 27) ||
	    dbackn_rx < -(1 << 27) || dbackn_rx >= (1 << 27)) {
		pr_err("tuphook: B out of range (tx=%lld rx=%lld)\n", dtx, drx);
		return -ERANGE;
	}
	g_bent_tx = tup_mkb(dtx);
	g_bent_rx = tup_mkb(drx);
	/* decode every branch back before writing a single word: a wrong sign
	 * or a bad site must refuse here, never oops in softirq context */
	if (tup_b_target(g_tx, g_bent_tx) != (unsigned long)tuphook_tramp_tx ||
	    tup_b_target(g_rx, g_bent_rx) != (unsigned long)tuphook_tramp_rx ||
	    tup_b_target((unsigned long)tuphook_back_tx, tup_mkb(dback_tx)) != g_tx + 4 ||
	    tup_b_target((unsigned long)tuphook_back_rx, tup_mkb(dback_rx)) != g_rx + 4 ||
	    tup_b_target((unsigned long)tuphook_backn_tx, tup_mkb(dbackn_tx)) != g_tx + 4 ||
	    tup_b_target((unsigned long)tuphook_backn_rx, tup_mkb(dbackn_rx)) != g_rx + 4) {
		pr_err("tuphook: branch self-check failed (tx->%lx rx->%lx want %lx/%lx)\n",
		       tup_b_target(g_tx, g_bent_tx), tup_b_target(g_rx, g_bent_rx),
		       (unsigned long)tuphook_tramp_tx,
		       (unsigned long)tuphook_tramp_rx);
		return -EINVAL;
	}

	/* one writable window for our .text page: four back-branches, the two
	 * 32-bit halves of the 64-bit percpu pool word, and the per-cpu base
	 * register of both trampolines */
	items[0].addr = tuphook_back_tx;
	items[0].insn = tup_mkb(dback_tx);
	items[1].addr = tuphook_backn_tx;
	items[1].insn = tup_mkb(dbackn_tx);
	items[2].addr = tuphook_back_rx;
	items[2].insn = tup_mkb(dback_rx);
	items[3].addr = tuphook_backn_rx;
	items[3].insn = tup_mkb(dbackn_rx);
	items[4].addr = (u32 *)pool;		/* low  half of P */
	items[4].insn = (u32)(P & 0xffffffffu);
	items[5].addr = (u32 *)pool + 1;	/* high half of P */
	items[5].insn = (u32)(P >> 32);
	items[6].addr = (u32 *)tuphook_mrs_tx;
	items[6].insn = mrs_insn;
	items[7].addr = (u32 *)tuphook_mrs_rx;
	items[7].insn = mrs_insn;
	rc = tup_patch_words(tpage, items, 8);
	if (rc) {
		pr_err("tuphook: trampoline patch failed: %d\n", rc);
		return rc;
	}

	/* one writable window for the mtk_warp entry page */
	items[0].addr = (void *)g_tx;
	items[0].insn = g_bent_tx;
	items[1].addr = (void *)g_rx;
	items[1].insn = g_bent_rx;
	rc = tup_patch_words(epage, items, 2);
	if (rc) {
		pr_err("tuphook: entry patch failed: %d\n", rc);
		return rc;
	}

	/* read back through the normal (RO) mapping */
	if (READ_ONCE(*(u32 *)g_tx) != g_bent_tx ||
	    READ_ONCE(*(u32 *)g_rx) != g_bent_rx ||
	    READ_ONCE(*(u32 *)tuphook_back_tx) != tup_mkb(dback_tx) ||
	    READ_ONCE(*(u32 *)tuphook_backn_tx) != tup_mkb(dbackn_tx) ||
	    READ_ONCE(*(u32 *)tuphook_back_rx) != tup_mkb(dback_rx) ||
	    READ_ONCE(*(u32 *)tuphook_backn_rx) != tup_mkb(dbackn_rx) ||
	    READ_ONCE(pool[0]) != (u64)P) {
		pr_err("tuphook: readback mismatch, rolling back\n");
		items[0].addr = (void *)g_tx;
		items[0].insn = INS_PACIASP;
		items[1].addr = (void *)g_rx;
		items[1].insn = INS_PACIASP;
		tup_patch_words(epage, items, 2);
		return -EIO;
	}
	installed = true;
	return 0;
}

static void tup_uninstall(void)
{
	struct patch_item items[2];
	unsigned long epage = g_tx & PAGE_MASK;

	if (!installed)
		return;
	items[0].addr = (void *)g_tx;
	items[0].insn = INS_PACIASP;
	items[1].addr = (void *)g_rx;
	items[1].insn = INS_PACIASP;
	if (READ_ONCE(*(u32 *)g_tx) != g_bent_tx ||
	    READ_ONCE(*(u32 *)g_rx) != g_bent_rx) {
		pr_warn("tuphook: entries changed by someone else, skip restore\n");
		installed = false;
		return;
	}
	if (tup_patch_words(epage, items, 2))
		pr_err("tuphook: restore failed (entries left patched!)\n");
	else if (READ_ONCE(*(u32 *)g_tx) != INS_PACIASP ||
		 READ_ONCE(*(u32 *)g_rx) != INS_PACIASP)
		pr_err("tuphook: restore readback mismatch\n");
	else
		pr_info("tuphook: entries restored to paciasp\n");
	installed = false;
}

/* ------------------------------------------------------------------ */
/* /proc/tuphook (seq_file: v1.4's 8 KB static buffer truncated the     */
/* ring readout; D19 needs the full per-record len/ip fields)          */
/* ------------------------------------------------------------------ */
static struct proc_dir_entry *tup_pe;
static DEFINE_MUTEX(tup_out_lock);

static unsigned int tup_show_n(void)
{
	if (maxread <= 0)
		return 64;
	if (maxread > TUP_NREC)
		return TUP_NREC;
	return (unsigned int)maxread;
}

static int tup_show(struct seq_file *m, void *v)
{
	unsigned int k = tup_show_n();
	u64 freq = 0, now = 0;
	int cpu;

	asm volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	asm volatile("mrs %0, cntvct_el0" : "=r"(now));
	seq_printf(m, "tuphook v1.5: %s base=%016lx\n",
		   installed ? "PATCHED" : (dryrun ? "dryrun" : "locate-only"),
		   g_base);
	seq_printf(m, "target: tx=%016lx rx=%016lx\n", g_tx, g_rx);
	seq_printf(m, "name:   %s | %s\n", g_txname, g_rxname);
	seq_printf(m, "offsets: len=0x%x nh=0x%x head=0x%x proto=0x%x\n",
		   SKB_OFF_LEN, SKB_OFF_NH, SKB_OFF_HEAD, SKB_OFF_PROTO);
	seq_printf(m, "clock: cntfrq=%llu now=%llu\n", freq, now);
	seq_puts(m, g_opsline);
	for_each_online_cpu(cpu) {
		struct tup_ring *r = per_cpu_ptr(rings, cpu);
		u64 head = READ_ONCE(r->head);
		u64 cnt = head >> 1;
		unsigned int show = cnt < k ? (unsigned int)cnt : k;
		unsigned int i;

		seq_printf(m, "cpu%d: recorded=%llu guard=%llu\n", cpu,
			   cnt, head & 1);
		for (i = 0; i < show; i++) {
			u64 seq = cnt - 1 - i;
			struct tup_rec *rec = &r->recs[seq & (TUP_NREC - 1)];
			u64 x0 = READ_ONCE(rec->x0);
			u64 x1 = READ_ONCE(rec->x1);
			u64 x2 = READ_ONCE(rec->x2);
			u64 x3 = READ_ONCE(rec->x3);
			u64 lip = READ_ONCE(rec->len_ip);
			u64 meta = READ_ONCE(rec->meta);
			u64 ts = READ_ONCE(rec->ts);
			u64 proto = READ_ONCE(rec->proto);
			u32 ip = (u32)(lip >> 32);
			u32 len = (u32)lip;

			seq_printf(m,
				   "  #%llu %s skb=%016llx ctx=%016llx band=%llx x3=%016llx len=%u ip=%u.%u.%u.%u st=%03llx ts=%llu proto=%04llx\n",
				   seq, (meta & TUP_M_RX) ? "rx" : "tx",
				   x2, x0, x1 & 0xff, x3, len,
				   (ip >> 24) & 0xff, (ip >> 16) & 0xff,
				   (ip >> 8) & 0xff, ip & 0xff,
				   meta, ts, proto & 0xffff);
		}
	}
	return 0;
}

static int tup_open(struct inode *inode, struct file *file)
{
	return single_open(file, tup_show, NULL);
}

static const struct proc_ops tup_pops = {
	.proc_open	= tup_open,
	.proc_read	= seq_read,
	/* 5.15.134's proc_reg_llseek() calls proc_lseek unconditionally
	 * (no NULL fallback), so a NULL here is a call to address 0. */
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* ------------------------------------------------------------------ */
static int __init tuphook_init(void)
{
	int rc, cpu;

	BUILD_BUG_ON(sizeof(struct tup_rec) != TUP_RECSZ);
	BUILD_BUG_ON(offsetof(struct tup_ring, head) != TUP_HEAD_OFF);
	BUILD_BUG_ON(offsetof(struct tup_ring, scratch) != TUP_HEAD_OFF + 8);
	/* D19 offset gate: pinned against the device kernel Image (see header) */
	BUILD_BUG_ON(offsetof(struct sk_buff, len) != SKB_OFF_LEN);
	BUILD_BUG_ON(offsetof(struct sk_buff, network_header) != SKB_OFF_NH);
	BUILD_BUG_ON(offsetof(struct sk_buff, head) != SKB_OFF_HEAD);
	BUILD_BUG_ON(offsetof(struct sk_buff, protocol) != SKB_OFF_PROTO);
	BUILD_BUG_ON(offsetof(struct sk_buff, data) != 0xc8);
	BUILD_BUG_ON(offsetof(struct iphdr, saddr) != IPH_OFF_SADDR);

	rings = alloc_percpu(struct tup_ring);
	if (!rings)
		return -ENOMEM;
	for_each_possible_cpu(cpu)
		memset(per_cpu_ptr(rings, cpu), 0, sizeof(struct tup_ring));

	rc = tup_resolve();
	if (rc) {
		pr_err("tuphook: resolve failed: %d\n", rc);
		goto out_free;
	}
	pr_info("tuphook: base=%016lx tx=%s rx=%s\n", g_base, g_txname,
		g_rxname);
	pr_info("tuphook: anchor warp_wlan_tx=%px - 0x%x\n", &warp_wlan_tx,
		TUP_OFF_WLAN_TX);
	pr_info("tuphook: skb offsets len=0x%x nh=0x%x head=0x%x proto=0x%x (BUILD_BUG_ON pinned)\n",
		SKB_OFF_LEN, SKB_OFF_NH, SKB_OFF_HEAD, SKB_OFF_PROTO);

	tup_report_bind_ops();
	pr_info("tuphook: %s", g_opsline);

	if (!dryrun) {
		rc = tup_install();
		if (rc)
			goto out_free;
		pr_info("tuphook: INSTALLED tx_b=%08x rx_b=%08x back_tx=%08x back_rx=%08x backn_tx=%08x backn_rx=%08x\n",
			g_bent_tx, g_bent_rx,
			READ_ONCE(*(u32 *)tuphook_back_tx),
			READ_ONCE(*(u32 *)tuphook_back_rx),
			READ_ONCE(*(u32 *)tuphook_backn_tx),
			READ_ONCE(*(u32 *)tuphook_backn_rx));
	} else {
		pr_info("tuphook: DRYRUN positive control complete, nothing patched\n");
	}

	tup_pe = proc_create("tuphook", 0444, NULL, &tup_pops);
	if (!tup_pe) {
		rc = -ENOMEM;
		goto out_uninstall;
	}
	return 0;
out_uninstall:
	tup_uninstall();
out_free:
	free_percpu(rings);
	rings = NULL;
	return rc;
}

static void __exit tuphook_exit(void)
{
	tup_uninstall();
	if (tup_pe)
		proc_remove(tup_pe);
	if (rings) {
		free_percpu(rings);
		rings = NULL;
	}
	pr_info("tuphook: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(tuphook_init);
module_exit(tuphook_exit);

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
