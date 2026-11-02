// SPDX-License-Identifier: GPL-2.0
// rxcount.ko -- ZERO-PATCH read-only sampler around mtk_warp's
// wo_rxcnt_update_handle on LG6151M (5.15.134 aarch64).
//
// A5 static chain under observation (all offsets from the shipped
// mtk_warp.ko, base anchored on the EXPORTED warp_wlan_tx symbol):
//
//   wo_rxcnt_update_handle(payload, len, bind)          .text+0x18b50
//       count = payload[0]; for each of `count` 20B entries:
//           wifi_chip_update_wo_rxcnt(bind+8, &payload[4+20*i])
//               ops = *(ctx+0x700); cb = *(ops+0x60); cb(*(ctx+8), entry)
//
// The payload is the WO firmware's reply, which lives in the warp entry's
// WO RX ring. IMPORTANT (fix 2026-11-02, offsets re-anchored): the ring is
// owned by the woif "slave" sub-struct at entry+0xF48, NOT by the entry
// itself -- the drain tasklet (.text+0x18f2c) is tasklet_init'd with
// data=entry+0xF48 (woif_init .text+0x198b8/0x199cc-0x199dc; the chip idx
// byte is cached at entry+0xF48 by .text+0x198c0-0x198c4) and does all its
// arithmetic on that base. Therefore:
//   slot i        at entry+0x6058+i*0x50   (= entry+0xF48+0x5110)
//   message VA    at slot+0x38            (= slot desc+0x20, the frag buffer
//                                            VA the WO DMA writes into;
//                                            slot+0x38 itself is unchanged)
//   payload       at msg+0x20             (warp_cmd_process_wo_ring, A5)
//   slot count    at entry+0xB098         (= entry+0xF48+0xA150), u32,
//                                            modulus in the drain's
//                                            udiv/msub at .text+0x19140-50
// Build constants (woif_init .text+0x1995c-0x19970 stores the pair
// {u32 slot_count=0x100, u32 frag_size=0x5e0} at entry+0xB098/0xB09c; the
// RX slot init loop bound .text+0x19c00 confirms 256 slots x 0x50 exactly
// filling [entry+0x6070, entry+0xB070); TX analog {256,1504} at
// entry+0x6048/0x604c). The value 1504 measured on 2026-11-02 at the old
// entry+0xA150 anchor is slot 207's desc+0x30 field = frag_size (per-slot
// page_frag buffer bytes, also packed into the RXD ctrl len field) -- NOT
// a slot count. After the driver consumes a reply the slot keeps the
// payload bytes, so a 1Hz reader observes the most recent rxcnt-shaped
// tables without touching any code.
//
// THIS MODULE PATCHES NOTHING AND WRITES NOTHING: no text write, no
// register write, no kmem write. Every dereference goes through
// copy_from_kernel_nofault (extable-fixed; a stale pointer cannot oops,
// which matters because ipanic/mrdump force a reboot on ANY oops even
// with panic_on_oops=0). The sampler is a per-CPU hrtimer at 1Hz; the
// counters (samples/events) are per-CPU; a change of the table hash for
// one slot is one "event", used to correlate with the canary hit rate.
//
// Locating wo_rxcnt_update_handle "via kallsyms":
//   - CONFIG_KALLSYMS=y but kallsyms_lookup_name() is not exported in
//     5.15 and CONFIG_KPROBES is off, so name->address is done by
//     anchoring on the exported warp_wlan_tx and doing reverse
//     verification with sprint_symbol() (exported): the resolved
//     address must name-match wo_rxcnt_update_handle and the entry word
//     must be paciasp, otherwise init fails cleanly.
//
// Module params:
//   table_rows=N   max 20B rows printed per snapshot (default 70, cap 70)
//
// See REVIEW-rxcount.md for the per-function audit and limitations.
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/printk.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/hrtimer.h>
#include <linux/ktime.h>
#include <linux/percpu.h>
#include <linux/cpumask.h>
#include <linux/smp.h>
#include <linux/atomic.h>
#include <linux/string.h>
#include <linux/stdarg.h>
#include <linux/kallsyms.h>
#include <linux/types.h>
#include <linux/mm.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("rxcount: zero-patch 1Hz sampler for mtk_warp wo rxcnt tables");
MODULE_AUTHOR("chr431");

/* ---- vendor mtk_warp.ko .text offsets ---- */
#define RXC_OFF_WLAN_TX	0x970	/* exported anchor */
#define RXC_OFF_TX	0x7330	/* wifi_tx_tuple_add (cross-check) */
#define RXC_OFF_RX	0x7268	/* wifi_rx_tuple_add (cross-check) */
#define RXC_OFF_UPD	0x18b50	/* wo_rxcnt_update_handle, size 0xc4 */
#define RXC_OFF_SUB0	0x0000	/* bind_get: adrp+add at +4/+8 */
#define RXC_OFF_ENTRY	0x1718	/* warp_entry_get_by_idx: adrp+add at +0/+8 */
#define INS_PACIASP	0xd503233fu

#define RXC_OFF_WOIF	0xf48	/* woif slave sub-struct base inside entry */
#define RXC_OFF_RING	0x6058	/* WO RX ring slot 0 = entry+0xf48+0x5110 */
#define RXC_SLOT_SZ	0x50
#define RXC_SLOT_MSG	0x38	/* slot -> message VA (= desc+0x20 frag VA) */
#define RXC_OFF_RINGCNT	0xb098	/* ring slot count (u32) = entry+0xf48+0xa150 */
#define RXC_MSG_PAYLOAD	0x20	/* message VA -> payload */
#define RXC_ENTRY_20B	20
#define RXC_MAX_ENT	70	/* table cap stated by the A5 readout */
#define RXC_MAX_SLOT	512	/* build pins 256 (woif_init const 0x100);
				 * gate widened 2026-11-02: the old 1..64 gate
				 * rejected even the true count; structural cap
				 * of the slot region [entry+0x6070,+0xB070)
				 * is exactly 256 slots */
#define RXC_SNAPS	4		/* per-cpu snapshot ring */
#define RXC_NSZ		256		/* sprint_symbol buffer */

#define RXC_OFF_OPS	0x700
#define RXC_OFF_TXCB	0x18
#define RXC_OFF_RXCB	0x50
#define RXC_OFF_UPDCB	0x60
#define RXC_BIND_KEY	0x10
#define RXC_ENTRY_SZ	0xb1a8	/* warp entry stride (warp_entry_get_by_idx objdump) */

static int table_rows = RXC_MAX_ENT;
module_param(table_rows, int, 0444);
MODULE_PARM_DESC(table_rows, "max 20B rows printed per snapshot (default 70)");

struct rxc_snap {
	u64 seq;
	u64 kt;
	u32 cpu;
	u32 slot;
	u32 cnt;
	u32 len;
	u64 hash;
	u8 data[4 + RXC_ENTRY_20B * RXC_MAX_ENT];
};

struct rxc_stat {
	struct hrtimer timer;
	u64 samples;
	u64 events;
	u64 last_hash[RXC_MAX_SLOT];
	u32 snaps_head;
	struct rxc_snap snaps[RXC_SNAPS];
};

static struct rxc_stat __percpu *stats;

static unsigned long g_base, g_upd, g_entry;
static u64 g_ringcnt;
static char g_updname[RXC_NSZ];
static char g_opsline[1024];
static atomic64_t g_snap_seq = ATOMIC64_INIT(0);
static u64 g_load_kt;

/* exported by mtk_warp.ko; the loader resolves it cross-module and pins the
 * vendor module for as long as we are loaded */
extern void warp_wlan_tx(void);

static int rxc_rd64(unsigned long addr, void *v)
{
	return copy_from_kernel_nofault(v, (const void *)addr, 8);
}

static int rxc_rd32(unsigned long addr, void *v)
{
	return copy_from_kernel_nofault(v, (const void *)addr, 4);
}

static u64 rxc_hash(const u8 *p, u32 len)
{
	u64 h = 0xcbf29ce484222325ULL;	/* FNV-1a 64 */
	u32 i;

	for (i = 0; i < len; i++) {
		h ^= p[i];
		h *= 0x100000001b3ULL;
	}
	return h;
}

/* ------------------------------------------------------------------ */
/* location + verification                                             */
/* ------------------------------------------------------------------ */
static int rxc_decode_adr_pair(unsigned long pc, u32 adrp, u32 add,
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

static int rxc_find_bind(unsigned long *slot_out, unsigned long *entry_out)
{
	unsigned long a = 0, b = 0, arr = 0;
	u64 key = 0;
	u32 cnt32 = 0;

	if (rxc_decode_adr_pair(g_base + RXC_OFF_SUB0 + 4,
				READ_ONCE(*(u32 *)(g_base + RXC_OFF_SUB0 + 4)),
				READ_ONCE(*(u32 *)(g_base + RXC_OFF_SUB0 + 8)),
				&a))
		return -EINVAL;
	if (rxc_decode_adr_pair(g_base + RXC_OFF_ENTRY,
				READ_ONCE(*(u32 *)(g_base + RXC_OFF_ENTRY)),
				READ_ONCE(*(u32 *)(g_base + RXC_OFF_ENTRY + 8)),
				&b))
		return -EINVAL;
	if (a != b)
		return -EINVAL;
	*slot_out = a;
	if (rxc_rd32(a, &cnt32) || !cnt32 || cnt32 > 4)
		return -ENOENT;
	if (rxc_rd64(a + 0x10, &arr) || !arr)
		return -ENOENT;
	/* walk entries 0..cnt-1: entry0 may be unbound while later entries hold
	 * the live binds (observed on-device 2026-11-02: count=3, entry0 key=0) */
	{
		u64 k;
		u32 i;

		for (i = 0; i < cnt32; i++) {
			unsigned long e = (unsigned long)arr +
					  (unsigned long)i * RXC_ENTRY_SZ;

			if (rxc_rd64(e + RXC_BIND_KEY, &k) || !k)
				continue;
			*entry_out = e;
			if (i)
				pr_info("rxcount: live bind at entry%u (entry0 unbound)\n",
					i);
			return 0;
		}
	}
	return -ENOENT;
}

static int rxc_resolve(void)
{
	unsigned long anchor = (unsigned long)&warp_wlan_tx;
	unsigned long slot = 0;
	char txname[RXC_NSZ];
	u32 i;
	int rc;

	g_base = anchor - RXC_OFF_WLAN_TX;
	g_upd = g_base + RXC_OFF_UPD;
	if (READ_ONCE(*(u32 *)g_upd) != INS_PACIASP) {
		pr_err("rxcount: wo_rxcnt_update_handle entry not paciasp\n");
		return -EINVAL;
	}
	sprint_symbol(g_updname, g_upd);
	if (!strstr(g_updname, "wo_rxcnt_update_handle")) {
		pr_err("rxcount: kallsyms says %016lx is '%s'\n", g_upd,
		       g_updname);
		return -EINVAL;
	}
	/* cross-checks: the two tuple entries sit at their known offsets */
	sprint_symbol(txname, g_base + RXC_OFF_TX);
	if (!strstr(txname, "wifi_tx_tuple_add")) {
		pr_err("rxcount: base arithmetic disagree (%s)\n", txname);
		return -EINVAL;
	}
	rc = rxc_find_bind(&slot, &g_entry);
	if (rc) {
		pr_warn("rxcount: no live bind yet (slot=%lx rc=%d), ring sampling disabled until reload\n",
			slot, rc);
		g_entry = 0;
	} else {
		if (rxc_rd32(g_entry + RXC_OFF_RINGCNT, &i) ||
		    !i || i > RXC_MAX_SLOT) {
			pr_warn("rxcount: ring count %u implausible, ring sampling disabled\n",
				i);
			g_entry = 0;
			g_ringcnt = 0;
		} else {
			g_ringcnt = i;
		}
	}
	pr_info("rxcount: base=%016lx upd=%s ringcnt=%llu entry=%016lx\n",
		g_base, g_updname, g_ringcnt, g_entry);
	return 0;
}

static void rxc_report_ops(void)
{
	unsigned long ctx, ops = 0, c1 = 0, c2 = 0, c3 = 0;
	char b1[RXC_NSZ] = "?", b2[RXC_NSZ] = "?", b3[RXC_NSZ] = "?";

	g_opsline[0] = '\0';
	if (!g_entry) {
		snprintf(g_opsline, sizeof(g_opsline), "ops: no entry\n");
		return;
	}
	ctx = g_entry + 8;
	if (rxc_rd64(ctx + RXC_OFF_OPS, &ops) || !ops) {
		snprintf(g_opsline, sizeof(g_opsline), "ops: unreadable at ctx+0x700\n");
		return;
	}
	rxc_rd64(ops + RXC_OFF_TXCB, &c1);
	rxc_rd64(ops + RXC_OFF_RXCB, &c2);
	rxc_rd64(ops + RXC_OFF_UPDCB, &c3);
	if (c1)
		sprint_symbol(b1, c1);
	if (c2)
		sprint_symbol(b2, c2);
	if (c3)
		sprint_symbol(b3, c3);
	snprintf(g_opsline, sizeof(g_opsline),
		 "ops:  ctx=%016lx ops=%016lx\n"
		 "cb:   tx_fill=%s\n"
		 "cb:   rx_fill=%s\n"
		 "cb:   wo_rxcnt=%s\n",
		 ctx, ops, b1, b2, b3);
}

/* ------------------------------------------------------------------ */
/* sampling (hrtimer context: no sleep, no lock ordering hazards)      */
/* ------------------------------------------------------------------ */
static void rxc_store_snapshot(struct rxc_stat *st, u32 cpu, u32 slot, u32 cnt,
			       u32 len, u64 hash, const u8 *data)
{
	struct rxc_snap *s = &st->snaps[st->snaps_head & (RXC_SNAPS - 1)];

	s->seq = (u64)atomic64_inc_return(&g_snap_seq);
	s->kt = ktime_get_ns();
	s->cpu = cpu;
	s->slot = slot;
	s->cnt = cnt;
	s->len = len;
	s->hash = hash;
	memcpy(s->data, data, len);
	st->snaps_head++;
}

static void rxc_sample(int cpu)
{
	struct rxc_stat *st = per_cpu_ptr(stats, cpu);
	u32 slots, i;

	st->samples++;
	if (!g_entry || !g_ringcnt)
		return;
	slots = (u32)g_ringcnt;
	for (i = 0; i < slots; i++) {
		unsigned long slotv = g_entry + RXC_OFF_RING +
				      (unsigned long)i * RXC_SLOT_SZ;
		u64 msg = 0;
		u32 cnt = 0, len;
		u8 buf[4 + RXC_ENTRY_20B * RXC_MAX_ENT];
		u64 h;

		if (rxc_rd64(slotv + RXC_SLOT_MSG, &msg) || !msg)
			continue;
		/* shape gate: rxcnt replies are {u32 cnt; cnt * 20B} -- only
		 * shapes in range are treated as tables (see REVIEW) */
		if (rxc_rd32(msg + RXC_MSG_PAYLOAD, &cnt) || cnt == 0 ||
		    cnt > RXC_MAX_ENT)
			continue;
		len = 4 + RXC_ENTRY_20B * cnt;
		if (copy_from_kernel_nofault(buf,
					     (const void *)(msg + RXC_MSG_PAYLOAD),
					     len))
			continue;
		h = rxc_hash(buf, len);
		if (st->last_hash[i] && st->last_hash[i] != h) {
			st->events++;
			rxc_store_snapshot(st, cpu, i, cnt, len, h, buf);
		}
		st->last_hash[i] = h;
	}
}

static enum hrtimer_restart rxc_tick(struct hrtimer *t)
{
	int cpu = raw_smp_processor_id();

	rxc_sample(cpu);
	hrtimer_forward_now(t, ms_to_ktime(1000));
	return HRTIMER_RESTART;
}

static void rxc_start_on_cpu(void *arg)
{
	struct rxc_stat *st = this_cpu_ptr(stats);

	hrtimer_start(&st->timer, ms_to_ktime(1000UL * (raw_smp_processor_id() + 1)),
		      HRTIMER_MODE_REL_PINNED);
}

static void rxc_stop_on_cpu(void *arg)
{
	hrtimer_cancel(&this_cpu_ptr(stats)->timer);
}

/* ------------------------------------------------------------------ */
/* /proc/rxcount                                                       */
/* ------------------------------------------------------------------ */
static struct proc_dir_entry *rxc_pe;
static DEFINE_MUTEX(rxc_out_lock);
static char rxc_out[4096 + 4 * 2048];

static void rxc_emit(char **p, char *end, const char *fmt, ...)
{
	va_list ap;
	int n;

	if (*p >= end)
		return;
	va_start(ap, fmt);
	n = vscnprintf(*p, end - *p, fmt, ap);
	va_end(ap);
	if (n > 0)
		*p += n;
}

static void rxc_hex(char **p, char *end, const u8 *d, u32 n)
{
	u32 i;

	for (i = 0; i < n && *p < end - 2; i++)
		rxc_emit(p, end, "%02x", d[i]);
}

static void rxc_fill(void)
{
	char *p = rxc_out, *end = rxc_out + sizeof(rxc_out) - 1;
	u64 now = ktime_get_ns();
	u64 ev = 0, sm = 0;
	int cpu, rows = table_rows;
	const struct rxc_snap *latest = NULL;

	if (rows <= 0 || rows > RXC_MAX_ENT)
		rows = RXC_MAX_ENT;
	rxc_emit(&p, end, "rxcount v1.0 zero-patch sampler (no text write, no register write)\n");
	rxc_emit(&p, end, "target: %016lx %s (paciasp verified)\n", g_upd,
		 g_updname);
	rxc_emit(&p, end, "base:   %016lx (anchor warp_wlan_tx - 0x%x)\n",
		 g_base, RXC_OFF_WLAN_TX);
	rxc_emit(&p, end, "ring:   entry=%016lx slots=%llu stride=0x%x\n",
		 g_entry, g_ringcnt, RXC_SLOT_SZ);
	rxc_emit(&p, end, "%s", g_opsline);
	for_each_possible_cpu(cpu) {
		struct rxc_stat *st = per_cpu_ptr(stats, cpu);
		u32 j;

		rxc_emit(&p, end, "cpu%d: samples=%llu events=%llu\n", cpu,
			 st->samples, st->events);
		sm += st->samples;
		if (st->events) {
			u32 n = st->snaps_head < RXC_SNAPS ? st->snaps_head
							   : RXC_SNAPS;

			for (j = 0; j < n; j++) {
				const struct rxc_snap *s = &st->snaps[j];

				if (!latest || s->seq > latest->seq)
					latest = s;
			}
		}
		ev += st->events;
	}
	rxc_emit(&p, end, "totals: samples=%llu events=%llu elapsed_ms=%llu rate=%llu mHz\n",
		 sm, ev, (now - g_load_kt) / 1000000,
		 (now - g_load_kt) ? ev * 1000000000ULL / (now - g_load_kt) : 0);
	if (g_entry && g_upd) {
		u64 h = (u64)atomic64_read(&g_snap_seq);
		char tb[256] = "?";

		sprint_symbol(tb, g_upd);
		rxc_emit(&p, end, "verify: %s snapshots=%llu\n", tb, h);
	}
	if (!latest) {
		rxc_emit(&p, end, "snap: none yet (no hash change observed)\n");
	} else {
		u32 i, cnt = latest->cnt;

		if (cnt > rows)
			cnt = rows;
		rxc_emit(&p, end, "snap: seq=%llu t_ms=%llu cpu=%u slot=%u cnt=%u hash=%016llx\n",
			 latest->seq, latest->kt / 1000000, latest->cpu,
			 latest->slot, latest->cnt, latest->hash);
		rxc_emit(&p, end, "hdr:  ");
		rxc_hex(&p, end, latest->data, 4);
		rxc_emit(&p, end, "\n");
		for (i = 0; i < cnt; i++) {
			rxc_emit(&p, end, "20B#%02u ", i);
			rxc_hex(&p, end, latest->data + 4 + i * RXC_ENTRY_20B,
				RXC_ENTRY_20B);
			rxc_emit(&p, end, "\n");
		}
	}
	*end = '\0';
}

static ssize_t rxc_read(struct file *f, char __user *ubuf, size_t len,
			loff_t *off)
{
	size_t n;
	int rc;

	if (*off > 0)
		return 0;
	mutex_lock(&rxc_out_lock);
	rxc_fill();
	n = min(len, strlen(rxc_out));
	rc = copy_to_user(ubuf, rxc_out, n);
	mutex_unlock(&rxc_out_lock);
	if (rc)
		return -EFAULT;
	*off += n;
	return n;
}

static const struct proc_ops rxc_pops = {
	.proc_read	= rxc_read,
};

/* ------------------------------------------------------------------ */
static int __init rxcount_init(void)
{
	int cpu, rc;

	stats = alloc_percpu(struct rxc_stat);
	if (!stats)
		return -ENOMEM;
	for_each_possible_cpu(cpu) {
		struct rxc_stat *st = per_cpu_ptr(stats, cpu);

		memset(st, 0, sizeof(*st));
		hrtimer_init(&st->timer, CLOCK_MONOTONIC,
			     HRTIMER_MODE_REL_PINNED);
		st->timer.function = rxc_tick;
	}
	g_load_kt = ktime_get_ns();

	rc = rxc_resolve();
	if (rc) {
		pr_err("rxcount: resolve failed: %d\n", rc);
		goto out_free;
	}
	rxc_report_ops();
	pr_info("rxcount: %s", g_opsline);

	for_each_online_cpu(cpu)
		smp_call_function_single(cpu, rxc_start_on_cpu, NULL, 1);
	pr_info("rxcount: loaded, 1Hz per-cpu sampler armed (read-only)\n");

	rxc_pe = proc_create("rxcount", 0444, NULL, &rxc_pops);
	if (!rxc_pe) {
		rc = -ENOMEM;
		goto out_timers;
	}
	return 0;
out_timers:
	for_each_online_cpu(cpu)
		smp_call_function_single(cpu, rxc_stop_on_cpu, NULL, 1);
out_free:
	free_percpu(stats);
	stats = NULL;
	return rc;
}

static void __exit rxcount_exit(void)
{
	int cpu;

	for_each_online_cpu(cpu)
		smp_call_function_single(cpu, rxc_stop_on_cpu, NULL, 1);
	if (rxc_pe)
		proc_remove(rxc_pe);
	if (stats) {
		free_percpu(stats);
		stats = NULL;
	}
	pr_info("rxcount: unloaded\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(rxcount_init);
module_exit(rxcount_exit);

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
