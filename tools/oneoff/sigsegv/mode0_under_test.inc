#define NR_TAGMASK 0x00FFFFFFFFFFFFFFULL
#define NR_LEN_MIN 0x400ULL
#define NR_LEN_MAX 0x20000ULL
static int shape_ok(uint64_t *w, uint64_t fault)
{
    uint64_t f = fault & NR_TAGMASK;
    uint64_t w0 = w[0] & NR_TAGMASK;
    uint64_t w1 = w[1], w2 = w[2], w3 = w[3];
    uint64_t lo0 = w[0] & 0xFFFFFFFFULL, lo2 = w[2] & 0xFFFFFFFFULL;
    int small0 = f > 0 && f < (1ULL << 24);
    int small2 = w2 > 0 && w2 < (1ULL << 24);
    int big0 = (f >> 32) != 0 && (f & 0xFFFFFFFFULL) != 0;
    int big2 = (w2 >> 32) != 0 && (w2 & 0xFFFFFFFFULL) != 0;

    if (w1 != 0 || w3 != 0) return 0;
    if (w0 != f && w0 != ((f + 8) & NR_TAGMASK)) return 0;
    if (small0 && big2) return lo2 >= NR_LEN_MIN && lo2 <= NR_LEN_MAX;
    if (big0 && small2) return lo0 >= NR_LEN_MIN && lo0 <= NR_LEN_MAX;
    return 0;
}
#define DEREF_SCAN_BYTES (16ULL * 1024ULL)
#define DEREF_SMALL_MAX  (1ULL << 24)
#define NR_LEN_LO 0x400ULL
#define NR_LEN_HI 0x20000ULL

/* is the faulting instruction a load?  (covers LDR/LDRB/LDRH/LDRSW imm-unsigned
 * and LDUR* unscaled; explicitly excludes the store forms and FP) */
static int is_load_insn(unsigned int insn)
{
    unsigned opc = (insn >> 22) & 3u;

    if ((insn >> 26) & 1u)              /* V=1: FP/SIMD load-store */
        return 0;
    if ((insn & 0x3B000000u) == 0x39000000u)   /* size 111 0 01 opc ... */
        return opc != 0;
    if ((insn & 0x3B200C00u) == 0x38000000u)   /* size 111 0 00 opc imm9 00 */
        return opc != 0;
    return 0;
}

/* v2.2: full shape classification for the XFORM census.  NEVER used to decide a
 * repair outside the gated paths.  Kinds:
 *   xf_popcopy  record at x2-0x240 (second copy) -- X1 candidate
 *   xf_bigderef load whose fault address is the B0A2 composite -- X2 candidate
 *   xf_regload  LDR (register offset), any size -- observation only
 *   xf_ldp      LDP/LDNP/LDPSW (pair load)     -- observation only
 *   xf_store    any store form                 -- observation only
 *   xf_fp       FP/SIMD load-store             -- observation only
 *   xf_null     si_addr == 0 with a record at x2 (cannot be distinguished from a
 *               genuine NULLL bug)              -- observation only
 *   xf_other    anything else                  -- observation only */
enum { xf_popcopy, xf_bigderef, xf_regload, xf_ldp, xf_store, xf_fp, xf_null, xf_other, xf_N };
static const char *xf_name(int i)
{
    static const char *n[xf_N] = { "popcopy", "bigderef", "regload", "ldp", "store", "fp", "null", "other" };

    return (i >= 0 && i < xf_N) ? n[i] : "?";
}
/* instruction class for the census; rt/rn/rm out-params are filled when meaningful */
static int xf_class(unsigned int insn, int *rt, int *rn, int *rm)
{
    *rt = insn & 0x1F;
    *rn = (insn >> 5) & 0x1F;
    *rm = (insn >> 16) & 0x1F;
    if ((insn >> 26) & 1u)
        return xf_fp;                                   /* V=1 */
    if ((insn & 0x3B200C00u) == 0x38200800u)            /* register offset */
        return (((insn >> 22) & 3u) != 0) ? xf_regload : xf_store;
    if ((insn & 0x3A000000u) == 0x28000000u && ((insn >> 22) & 1u))
        return xf_ldp;                                  /* L=1, integer pair */
    if (is_load_insn(insn))
        return xf_other;                                /* imm-form load (path 2) */
    if ((insn & 0x3B000000u) == 0x39000000u ||
        (insn & 0x3B200C00u) == 0x38000000u ||
        (insn & 0x3A000000u) == 0x28000000u)
        return xf_store;                                /* imm/unscaled/pair store */
    return xf_other;
}

/* coarse class label for the NEAR read-out (never used to decide a repair) */
static const char *classify_insn(unsigned int insn)
{
    unsigned opc = (insn >> 22) & 3u;

    if ((insn >> 26) & 1u) return "fp";
    if ((insn & 0x3B200C00u) == 0x38000000u)
        return opc ? "ldur" : "stur";
    if ((insn & 0x3B000000u) == 0x39000000u) {
        switch ((insn >> 30) & 3u) {
        case 0: return opc ? "ldrb" : "strb";
        case 1: return opc ? "ldrh" : "strh";
        default: return opc ? "ldr" : "str";
        }
    }
    return "other";
}

static int len_band(uint64_t v)
{
    return v >= NR_LEN_LO && v <= NR_LEN_HI;
}

/* search [sp, sp+16K) of the faulting task for a 32 B family record that carries
 * si_addr in q0 or low32(q2).  Page-by-page so an unmapped hole does not abort
 * the whole scan.  Returns 1 and fills the out-params on a hit.
 * v2.2: mode 1 (big) is the B0A2 form -- the fault address IS the {len,ip}
 * composite, so only an exact q0 match (tag-masked) plus the full shape_ok()
 * gate is accepted.  mode 2 (X3) is the q0-match branch of the small-address
 * form, gated by shape_ok() instead of the v2.0 len_band(lo0) check: that check
 * compares the A word itself against the LENGTH band, so it structurally rejects
 * A values > 0x20000 (6 of the 7 natural-NE records carry A in 0x20085..0x23648).
 * mode 0 keeps the v2.0 semantics byte for byte. */
static int find_record_near_stack(pid_t pid, uint64_t sp, uint64_t addr,
                                  uint64_t *out_va, uint64_t *out_q0,
                                  uint64_t *out_q2, int *out_which, int mode)
{
    static unsigned char buf[4096];
    uint64_t base = sp & ~0xFFFULL;
    uint64_t p;
    int pg;

    for (pg = 0; pg < (int)(DEREF_SCAN_BYTES / 4096); pg++) {
        uint64_t va = base + (uint64_t)pg * 4096ULL;
        uint64_t off;

        if (read_mem(pid, va, buf, 4096) < 0)
            continue;
        g_deref_scan++;
        /* stride 8.  Measured: the 4 natural-NE records sit at page offsets
         * 0x8ea8/0x8ff0/0xebc8/0x8840/0x9168/0x92b0/0xec70 -- all 8-aligned but
         * NOT all 16-aligned, so a 16 B stride would miss them.  A window that
         * starts inside a record can also match (when the fault address equals
         * the record's length word); that only costs evidence quality, never
         * correctness -- the repair action is identical. */
        for (off = 0; off + 32 <= 4096; off += 8) {
            uint64_t q0, q1, q2, q3, lo0, lo2;

            q0 = *(uint64_t *)(buf + off);
            q1 = *(uint64_t *)(buf + off + 8);
            q2 = *(uint64_t *)(buf + off + 16);
            q3 = *(uint64_t *)(buf + off + 24);
            if (q1 != 0 || q3 != 0)
                continue;
            if (mode) {
                uint64_t w[4];

                if ((q0 & NR_TAGMASK) != (addr & NR_TAGMASK) &&
                    !(mode == 2 && (q0 & NR_TAGMASK) == ((addr + 8) & NR_TAGMASK)))
                    continue;
                w[0] = q0; w[1] = q1; w[2] = q2; w[3] = q3;
                if (!shape_ok(w, addr))
                    continue;
                *out_va = va + off; *out_q0 = q0; *out_q2 = q2; *out_which = 0;
                return 1;
            }
            lo0 = q0 & 0xFFFFFFFFULL;
            lo2 = q2 & 0xFFFFFFFFULL;
            if (lo2 == addr || lo2 == addr + 8 || lo2 == addr - 8) {
                if (!len_band(lo2))
                    continue;
                *out_va = va + off; *out_q0 = q0; *out_q2 = q2; *out_which = 2;
                return 1;
            }
            if (lo0 == addr || lo0 == addr + 8 || lo0 == addr - 8) {
                if (!len_band(lo0))
                    continue;
                *out_va = va + off; *out_q0 = q0; *out_q2 = q2; *out_which = 0;
                return 1;
            }
        }
        p = va;
        (void)p;
    }
    return 0;
}

/* v2.2: could this fault address have come from a family record?  Bounds the
 * cost of the observation scan to faults that are worth the 16 KB walk. */
static int addr_family_plausible(uint64_t a)
{
    if (a && a < DEREF_SMALL_MAX)
        return 1;
    return len_band(a & 0xFFFFFFFFULL) && (a >> 32) != 0;   /* B0A2 composite */
}

/* returns 1 if this fault was handled by the dereference-type path */
