/* nerepair_mode0_test.c -- host regression for the deref path-2 MODE 0 gate.
 *
 * WHY: nerepair v2.2's deref path-2 default (mode 0 = find_record_near_stack(...,mode=0))
 *      does NOT call shape_ok().  Its gate is:
 *          w1 == 0 && w3 == 0
 *          && ( low32(q0) in {addr-8, addr, addr+8}  && len_band(low32(q0)) )
 *          || ( low32(q2) in {addr-8, addr, addr+8}  && len_band(low32(q2)) )
 *      The existing host regression (nerepair_mask_test.c) only exercises shape_ok, so the
 *      mode-0 false-positive surface was never measured -- and mode 0 is the ARMED default
 *      on the device since 2026-11-03 19:55 (dry -> armed, no reboot).
 *
 * Criteria source: build_mode0_test.sh re-extracts them from the LIVE gw/src/nerepair.c at
 * build time (three sed ranges) and applies ONE documented mechanical normalization:
 *      s/unsigned long/uint64_t/g ; s/UL/ULL/g
 * because this host is LLP64 (unsigned long is 32 BIT here, 64 bit on the aarch64 target;
 * the existing deref_test.c relies on the same distinction).  The normalization changes the
 * TYPE WIDTH only -- every operator, constant and branch is untouched -- and it is proven
 * behaviourally by the positive/negative controls printed at the end of the run:
 *      control A: shape_ok must accept 150/150 real corpus records (exercises the big2 branch
 *                 that a 32-bit host silently kills);
 *      control B: shape_ok must reject all F1a {V,0,0,0} samples.
 *
 * Build+run:  sh tools/oneoff/sigsegv/build_mode0_test.sh [path/to/h4_rec150.txt]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <sys/types.h>

/* ---------- stub: a synthetic 16 KiB "stack" we fully control ---------- */
#define IMG_PAGES 4
static uint8_t g_img[IMG_PAGES * 4096];
static const uint64_t g_base = 0x7f0000000000ULL;

static uint64_t g_deref_scan;               /* referenced by find_record_near_stack */

static int read_mem(pid_t pid, uint64_t addr, void *buf, size_t len)
{
    (void)pid;
    if (addr < g_base || addr + len > g_base + sizeof g_img) return -1;
    memcpy(buf, g_img + (addr - g_base), len);
    return 0;
}

#include "mode0_under_test.inc"   /* generated+normalized: defines, shape_ok, len_band, find_record_near_stack */

_Static_assert(sizeof(uint64_t) == 8, "uint64_t must be 64 bit");

/* ---------- helpers ---------- */
static uint64_t rd64(uint64_t off) { uint64_t v; memcpy(&v, g_img + off, 8); return v; }
static void wr64(uint64_t off, uint64_t v) { memcpy(g_img + off, &v, 8); }
static void img_zero(void) { memset(g_img, 0, sizeof g_img); }

static uint64_t rng_s = 0x123456789abcdefULL;
static uint64_t rnd(void)
{
    rng_s ^= rng_s >> 12; rng_s ^= rng_s << 25; rng_s ^= rng_s >> 27;
    return rng_s * 0x2545F4914F6CDD1DULL;
}
static uint64_t band_val(void) { return 0x400ULL + (rnd() % (0x20000ULL - 0x400ULL)); }

/* ---------- the predicates ---------- */
static int g_m0, g_prop, g_shape_on_hit, g_which;
static uint64_t g_hit_off;

static void run_sample(uint64_t addr)
{
    uint64_t recva = 0, q0 = 0, q2 = 0, hit_off;
    int w = -1;
    g_m0 = g_prop = g_shape_on_hit = 0; g_which = -1;
    if (!find_record_near_stack(0, g_base, addr, &recva, &q0, &q2, &w, 0)) return;
    g_m0 = 1; g_which = w; hit_off = recva - g_base; g_hit_off = hit_off;
    {   /* shape_ok on the very window the hit landed on, using that window's own w0 */
        uint64_t ww[4]; int i;
        for (i = 0; i < 4; i++) ww[i] = rd64(hit_off + 8ULL * (uint64_t)i);
        g_shape_on_hit = shape_ok(ww, ww[0]);
    }
    {   /* proposed gate: full record shape on the 8-aligned window(s) that could hold the matched word */
        long cand[2]; int n = 0, i;
        if (w == 0) { cand[n++] = (long)hit_off; cand[n++] = (long)hit_off - 16; }
        else        { cand[n++] = (long)hit_off; cand[n++] = (long)hit_off + 16; }
        for (i = 0; i < n; i++) {
            uint64_t ww[4]; int k;
            if (cand[i] < 0) continue;
            if ((uint64_t)cand[i] + 32 > sizeof g_img) continue;
            for (k = 0; k < 4; k++) ww[k] = rd64((uint64_t)cand[i] + 8ULL * (uint64_t)k);
            if (shape_ok(ww, ww[0])) { g_prop = 1; break; }
        }
    }
}

/* ---------- Wilson 95% CI ---------- */
static void wilson(int k, int n, double *lo, double *hi)
{
    const double z = 1.959963984540054;
    double p, d, c, h;
    if (n <= 0) { *lo = *hi = 0; return; }
    p = (double)k / (double)n;
    d = 1.0 + z * z / (double)n;
    c = (p + z * z / (2.0 * (double)n)) / d;
    h = z * sqrt((p * (1.0 - p) + z * z / (4.0 * (double)n)) / (double)n) / d;
    *lo = c - h; *hi = c + h;
    if (*lo < 0) *lo = 0;
    if (*hi > 1) *hi = 1;
}

/* ---------- families ---------- */
#define MAXFAM 16
struct fam { const char *name; int n, m0, prop, shapehit; };
static struct fam fams[MAXFAM];
static int nfam;
static void fam_begin(const char *name)
{
    struct fam *f = &fams[nfam++];
    f->name = name; f->n = f->m0 = f->prop = f->shapehit = 0;
}
static void fam_acc(int idx, int which_hist[3])
{
    fams[idx].n++; fams[idx].m0 += g_m0; fams[idx].prop += g_prop; fams[idx].shapehit += g_shape_on_hit;
    if (which_hist && g_which >= 0) which_hist[g_which]++;
}

static void stamp_sparse(double p_zero, double p_small)
{
    int i;
    img_zero();
    for (i = 0; i < IMG_PAGES * 4096 / 8; i++) {
        double r = (double)(rnd() >> 11) / 9007199254740992.0;
        uint64_t v;
        if (r < p_zero) v = 0;
        else if (r < p_zero + p_small) v = band_val();
        else v = (uint64_t)(rnd() & 0xffffffffULL) | ((uint64_t)(rnd() & 0xffffULL) << 48);
        wr64((uint64_t)i * 8ULL, v);
    }
}
static uint64_t pick_present_band_val(void)
{
    int tries, i;
    for (tries = 0; tries < 4096; tries++) {
        i = (int)(rnd() % (IMG_PAGES * 4096 / 8));
        if (rd64((uint64_t)i * 8ULL) >= 0x400ULL && rd64((uint64_t)i * 8ULL) <= 0x20000ULL)
            return rd64((uint64_t)i * 8ULL);
    }
    return 0;
}

#define MAXREC 512
static uint64_t rec_w[MAXREC][4];
static int nrec;
static void load_corpus(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[512];
    if (!f) { printf("corpus: MISSING (%s)\n", path); return; }
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        unsigned long long ts, w0, w1, w2, w3;
        while (*p == ' ') p++;
        if (sscanf(p, "%llu %llx %llx", &ts, &w0, &w1) != 3) continue;
        if (!fgets(line, sizeof line, f)) break;
        p = line;
        while (*p == ' ') p++;
        if (sscanf(p, "%llx %llx", &w2, &w3) != 2) continue;
        if (nrec >= MAXREC) break;
        rec_w[nrec][0] = w0; rec_w[nrec][1] = w1; rec_w[nrec][2] = w2; rec_w[nrec][3] = w3;
        nrec++;
    }
    fclose(f);
    printf("corpus: %s -> %d records\n", path, nrec);
}

static void stamp_record(int i)
{
    uint64_t off = 0xea8ULL;                 /* 8-aligned, like the natural-NE records */
    img_zero();
    wr64(off, rec_w[i][0]); wr64(off + 8ULL, rec_w[i][1]);
    wr64(off + 16ULL, rec_w[i][2]); wr64(off + 24ULL, rec_w[i][3]);
}

static void print_fam(int i)
{
    double lo, hi, lo2, hi2;
    wilson(fams[i].m0, fams[i].n, &lo, &hi);
    wilson(fams[i].prop, fams[i].n, &lo2, &hi2);
    printf("%-48s n=%-4d mode0=%-4d %6.1f%% [%5.1f-%5.1f]  proposed=%-4d %6.1f%% [%5.1f-%5.1f]  shape_on_hit=%d\n",
           fams[i].name, fams[i].n, fams[i].m0, 100.0 * (double)fams[i].m0 / fams[i].n, 100.0 * lo, 100.0 * hi,
           fams[i].prop, 100.0 * (double)fams[i].prop / fams[i].n, 100.0 * lo2, 100.0 * hi2, fams[i].shapehit);
}

int main(int argc, char **argv)
{
    const char *corpus = argc > 1 ? argv[1] : "h4_rec150.txt";
    int i, sweep;

    printf("=== nerepair v2.2 deref path-2 MODE 0 -- host negative corpus ===\n");
    printf("host sizeof(unsigned long)=%d (LLP64 -> extracted code is normalized to uint64_t by the build script)\n",
           (int)sizeof(unsigned long));
    printf("mode-0 gate as shipped: w1==0 && w3==0 && (low32(q0)|low32(q2)) in {addr-8,addr,addr+8} and in [0x400,0x20000]\n\n");

    /* ---- F1a ---- */
    fam_begin("F1a {V,0,0,0} addr=V (509 offsets)");
    for (i = 0; i < 509; i++) {
        uint64_t off = (uint64_t)i * 8ULL;
        uint64_t V = 0x400ULL + (uint64_t)((unsigned long long)i * (0x20000ULL - 0x400ULL) / 509ULL);
        img_zero(); wr64(off, V);
        run_sample(V); fam_acc(nfam - 1, NULL);
    }
    /* ---- F1b ---- */
    fam_begin("F1b {V,0,0,0} addr=V-8 (200)");
    for (i = 0; i < 200; i++) {
        uint64_t off = (uint64_t)((i * 8) % 4000), V;
        do { V = band_val(); } while (V < 0x408ULL);
        img_zero(); wr64(off, V);
        run_sample(V - 8ULL); fam_acc(nfam - 1, NULL);
    }
    /* ---- F2a / F2b ---- */
    fam_begin("F2a {V1,0,V2,0} addr=V2 (300)");
    for (i = 0; i < 300; i++) {
        uint64_t off = (uint64_t)((i * 8) % 4000), V1 = band_val(), V2 = band_val() | 1ULL;
        img_zero(); wr64(off, V1); wr64(off + 16ULL, V2);
        run_sample(V2); fam_acc(nfam - 1, NULL);
    }
    fam_begin("F2b {V1,0,V2,0} addr=V1 (200)");
    for (i = 0; i < 200; i++) {
        uint64_t off = (uint64_t)((i * 8) % 4000), V1 = band_val() | 1ULL, V2 = band_val();
        img_zero(); wr64(off, V1); wr64(off + 16ULL, V2);
        run_sample(V1); fam_acc(nfam - 1, NULL);
    }
    /* ---- F3 sensitivity sweep ---- */
    for (sweep = 0; sweep < 4; sweep++) {
        static const double pz[4] = { 0.40, 0.55, 0.70, 0.90 };
        char nm[90];
        int k;
        snprintf(nm, sizeof nm, "F3 sparse p_zero=%.2f addr=present int (500)", pz[sweep]);
        fam_begin(nm);
        for (k = 0; k < 500; k++) {
            uint64_t a;
            stamp_sparse(pz[sweep], 0.25);
            a = pick_present_band_val();
            run_sample(a ? a : 0x1000ULL); fam_acc(nfam - 1, NULL);
        }
    }
    /* ---- F4 controls: addresses outside the len band ---- */
    fam_begin("F4a sparse, addr<0x400 (250)");
    for (i = 0; i < 250; i++) {
        static const uint64_t small[5] = { 0x0ULL, 0x8ULL, 0x40ULL, 0x100ULL, 0x3ffULL };
        stamp_sparse(0.55, 0.25);
        run_sample(small[i % 5]); fam_acc(nfam - 1, NULL);
    }
    fam_begin("F4b sparse, addr>0x20000 (250)");
    for (i = 0; i < 250; i++) {
        static const uint64_t mid[6] = { 0x20001ULL, 0x40000ULL, 0x80000ULL, 0x100000ULL, 0x400000ULL, 0x800000ULL };
        stamp_sparse(0.55, 0.25);
        run_sample(mid[i % 6]); fam_acc(nfam - 1, NULL);
    }
    /* ---- F5 uniform random ---- */
    fam_begin("F5 uniform random image, addr in band (500)");
    for (i = 0; i < 500; i++) {
        int k;
        for (k = 0; k < IMG_PAGES * 4096 / 8; k++) wr64((uint64_t)k * 8ULL, rnd() | 1ULL);
        run_sample(band_val()); fam_acc(nfam - 1, NULL);
    }
    /* ---- corpus ---- */
    load_corpus(corpus);
    if (nrec > 0) {
        int wh[3] = { 0, 0, 0 };
        fam_begin("F6 real records, addr=low32(w2)=len (150)");
        for (i = 0; i < nrec; i++) {
            stamp_record(i);
            run_sample(rec_w[i][2] & 0xFFFFFFFFULL);
            if (i < 2) printf("dbg F6[%d] addr=0x%llx hit_off=0x%llx which=%d shape_on_hit=%d\n",
                            i, (unsigned long long)(rec_w[i][2] & 0xFFFFFFFFULL), (unsigned long long)g_hit_off, g_which, g_shape_on_hit);
            fam_acc(nfam - 1, wh);
        }
        printf("F6 which-histogram: which=0 %d, which=2 %d\n", wh[0], wh[2]);

        {
            int a0b2 = 0, b0a2 = 0, inband = 0, m0 = 0, prop = 0, sh = 0;
            double lo, hi;
            fam_begin("P real records, addr=w0 (size-gate check)");
            for (i = 0; i < nrec; i++) {
                int is_a0b2 = (rec_w[i][0] < (1ULL << 24));
                stamp_record(i);
                run_sample(rec_w[i][0]);
                m0 += g_m0; prop += g_prop; sh += g_shape_on_hit;
                if (is_a0b2) { a0b2++; if (rec_w[i][0] >= 0x400ULL && rec_w[i][0] <= 0x20000ULL) inband++; }
                else { b0a2++; }
                if (i < 3) printf("dbg P[%d] addr=0x%llx hit_off=0x%llx which=%d shape_on_hit=%d proposed=%d\n",
                                 i, (unsigned long long)rec_w[i][0], (unsigned long long)g_hit_off, g_which, g_shape_on_hit, g_prop);
                fam_acc(nfam - 1, NULL);
            }
            wilson(m0, nrec, &lo, &hi);
            printf("P  forms: nrec=%d  A0B2(w0<2^24)=%d  B0A2=%d  sum=%d ; of A0B2, w0 in len band=%d\n",
                   nrec, a0b2, b0a2, a0b2 + b0a2, inband);
            { int q; for (q = 0; q < 4 && q < nrec; q++)
                printf("dbg rec[%d] w0=0x%llx w2=0x%llx (w0 in band=%d, low32(w2) in band=%d)\n", q,
                       (unsigned long long)rec_w[q][0], (unsigned long long)rec_w[q][2],
                       (rec_w[q][0] >= 0x400ULL && rec_w[q][0] <= 0x20000ULL),
                       ((rec_w[q][2] & 0xFFFFFFFFULL) >= 0x400ULL && (rec_w[q][2] & 0xFFFFFFFFULL) <= 0x20000ULL)); }
            printf("P  mode0 accepted %d/%d = %.1f%% [Wilson 95%% %.1f-%.1f%%]; shape_ok-on-hit %d/%d\n",
                   m0, nrec, 100.0 * (double)m0 / nrec, 100.0 * lo, 100.0 * hi, sh, nrec);
        }
        /* controls: shape_ok must accept every real record (exercises the big2 branch) */
        {
            int acc = 0;
            for (i = 0; i < nrec; i++) {
                uint64_t w[4];
                w[0] = rec_w[i][0]; w[1] = rec_w[i][1]; w[2] = rec_w[i][2]; w[3] = rec_w[i][3];
                acc += shape_ok(w, w[0]);
            }
            printf("control A: shape_ok(record, w0) accepts %d/%d real records (expect 150/150)\n", acc, nrec);
        }
        /* control B: shape_ok must reject the F1a shape */
        {
            int acc = 0, k;
            for (k = 0; k < 100; k++) {
                uint64_t w[4]; uint64_t V = band_val();
                w[0] = V; w[1] = 0; w[2] = 0; w[3] = 0;
                acc += shape_ok(w, V);
            }
            printf("control B: shape_ok({V,0,0,0}, V) accepts %d/100 (expect 0/100)\n", acc);
        }
    }

    printf("\n=== per-family summary (Wilson 95%% CI) ===\n");
    for (i = 0; i < nfam; i++) print_fam(i);
    printf("\nlegend: mode0 = shipped mode-0 gate accepts (a FALSE POSITIVE for every F1..F5 sample);\n");
    printf("        proposed = mode-0 geometry + full shape_ok on the +-16-related 8-aligned window;\n");
    printf("        shape_on_hit = would shape_ok have accepted the window the hit landed on.\n");
    return 0;
}
