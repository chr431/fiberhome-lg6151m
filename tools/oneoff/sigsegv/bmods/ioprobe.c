// SPDX-License-Identifier: GPL-2.0
// ioprobe.ko -- CCB/MMIO reachability probe for LG6151M (5.15.134 aarch64).
//
// Background (A3/A4): reads of CCB (0x94000000-0x9820ffff), medmcu
// reserved/desc, netsys and WED register windows through /dev/mem silently
// return empty (no SEA).  This module maps each probe point with kernel-side
// ioremap() and reads 16 bytes, printing raw values plus per-point failure
// reasons, so kernel-attribute access can be compared with the userspace
// result.  Read-only: it NEVER writes any register and holds no mapping
// after init returns.
//
//   insmod ioprobe.ko                      -> default table below
//   insmod ioprobe.ko addrs="0x94000000,0x15105c00"
//   insmod ioprobe.ko cached=1             -> second pass with ioremap_cache()
//                                             (normal cacheable attributes;
//                                             speculative reads possible --
//                                             opt-in, see REVIEW-ioprobe.md)
//
// Two mapping states per point: ioremap() = Device nGnRE ("nocache"), and,
// when cached=1, ioremap_cache() = normal cacheable.  Reads are aligned
// 8-byte volatile loads (__raw_readq), 2 per probe.
//
// Residual risk (documented in REVIEW-ioprobe.md): a synchronous external
// abort on an aborting bus region is NOT covered by any extable fixup on
// arm64 5.15 (do_sea has no fixup_exception path) and would oops with the
// device's panic_on_oops=1 -> reboot.  A3/A4 userspace evidence (same
// physical windows, noncached attributes, silent zero reads, no SEA) is the
// safety argument for this default table; probe unknown regions one at a
// time and read the default ordering (RAM-like first, WED/netsys last).
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <asm/io.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ioprobe: read-only CCB/MMIO reachability probe (16B, ioremap)");
MODULE_AUTHOR("chr431");

#define IOP_MAX 24
#define IOP_BYTES 16

static char *addrs;
static int cached;

module_param(addrs, charp, 0444);
MODULE_PARM_DESC(addrs, "comma-separated physical hex addresses to probe (default table if empty)");
module_param(cached, int, 0444);
MODULE_PARM_DESC(cached, "1 = also probe with ioremap_cache (speculative reads possible)");

/* Default table: RAM-like reserved windows first, live register blocks last,
 * so printk order preserves the safest evidence first.  Sources:
 * task/C-184 (CCB), 05_LOG/2026-11-01-wed-md-romap.md (medmcu windows),
 * 05_LOG/2026-11-01-09-a4-fe-wed-ring-dump.md DT dump (ethsys/netsys/wed),
 * 08-a3 log (wocpu/scp).  consys@0x18000000 was REMOVED from the default
 * table: S0 measured a synchronous external abort (SEA) on that window --
 * the one abort region must never be probed by a default-table run. */
static const struct {
	unsigned long pa;
	const char *name;
} dflt_probes[] = {
	{ 0x94000000, "ccb_base" },	/* CCB 0x94000000-0x9820ffff */
	{ 0x9820f000, "ccb_tail" },
	{ 0x9fcb0000, "medmcu_desc" },	/* lk_medmcu_reserved_desc +0x340000 */
	{ 0xaff00000, "lk_medmcu" },	/* lk_medmcu_reserved +0x40000 */
	{ 0x15000000, "ethsys" },	/* ethsys@0x15000000 sz 0x10000 */
	{ 0x151e0000, "wocpu_ilm" },	/* WO ilm window */
	{ 0x15d00000, "scp_sram" },	/* SCP SRAM */
	{ 0x15100000, "netsys" },	/* netsys@0x15100000 sz 0x20000 */
	{ 0x15105c00, "netsys_txring" },/* A4 blocked read point */
	{ 0x15010000, "wed1" },	/* wed@0x15010000 */
	{ 0x15011000, "wed2" },
	{ 0x15012000, "wed3" },
};

static unsigned long probe_pa[IOP_MAX];
static const char *probe_nm[IOP_MAX];
static int nprobe;

/* tiny standalone hex parser (no library dependency) */
static int iop_hex(const char *s, unsigned long *out)
{
	unsigned long v = 0;
	int seen = 0;

	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s += 2;
	for (; *s; s++) {
		char c = *s;
		int d;

		if (c >= '0' && c <= '9')
			d = c - '0';
		else if (c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			return seen ? 0 : -1;
		v = (v << 4) | d;
		seen = 1;
	}
	*out = v;
	return seen ? 0 : -1;
}

static int iop_parse_addrs(char *s)
{
	char *p = s;

	while (p && *p && nprobe < IOP_MAX) {
		char *end = strchr(p, ',');
		unsigned long v;

		if (end)
			*end = '\0';
		if (iop_hex(p, &v)) {
			pr_err("ioprobe: bad hex token '%s'\n", p);
			return -EINVAL;
		}
		probe_pa[nprobe] = v;
		probe_nm[nprobe] = "user";
		nprobe++;
		p = end ? end + 1 : NULL;
	}
	return nprobe ? 0 : -EINVAL;
}

static void iop_one(int idx, int cache_mode)
{
	void __iomem *b;
	u64 r0, r1;
	const char *attrs = cache_mode ? "cache" : "nGnRE";

	b = cache_mode ? ioremap_cache(probe_pa[idx], IOP_BYTES)
		       : ioremap(probe_pa[idx], IOP_BYTES);
	if (!b) {
		pr_info("ioprobe[%d] %-15s pa=%016lx attrs=%s map=FAILED (NULL)\n",
			idx, probe_nm[idx], probe_pa[idx], attrs);
		return;
	}
	r0 = __raw_readq(b);
	r1 = __raw_readq((u8 __iomem *)b + 8);
	iounmap(b);
	pr_info("ioprobe[%d] %-15s pa=%016lx attrs=%s r0=%016llx r1=%016llx%s%s\n",
		idx, probe_nm[idx], probe_pa[idx], attrs, r0, r1,
		(r0 == 0 && r1 == 0) ? " (all-zero)" : "",
		(r0 == ~0ULL && r1 == ~0ULL) ? " (all-ff)" : "");
}

static int __init ioprobe_init(void)
{
	int i;

	if (addrs && *addrs) {
		if (iop_parse_addrs(addrs)) {
			pr_err("ioprobe: no valid address in addrs= '%s'\n", addrs);
			return -EINVAL;
		}
	} else {
		nprobe = ARRAY_SIZE(dflt_probes);
		for (i = 0; i < nprobe; i++) {
			probe_pa[i] = dflt_probes[i].pa;
			probe_nm[i] = dflt_probes[i].name;
		}
	}

	pr_info("ioprobe: %d point(s), %d bytes each, READ ONLY, cached_pass=%d%s\n",
		nprobe, IOP_BYTES, cached,
		cached ? " (WARNING: cacheable MMIO allows speculative reads)" : "");
	for (i = 0; i < nprobe; i++) {
		iop_one(i, 0);
		if (cached)
			iop_one(i, 1);
	}
	pr_info("ioprobe: pass complete (no mappings held)\n");
	return 0;
}

static void __exit ioprobe_exit(void)
{
	pr_info("ioprobe: unloaded (init-time probe only, nothing to clean)\n");
}

static const u64 __plt_entries[16] __section(".plt") __attribute__((used)) = {0};
static const u64 __init_plt_entries[8] __section(".init.plt") __attribute__((used)) = {0};

module_init(ioprobe_init);
module_exit(ioprobe_exit);

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
