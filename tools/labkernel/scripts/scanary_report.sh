#!/bin/sh
# scanary_report -- on-device scanary log summarizer (busybox awk; no python).
# Part of the C2 lab-kernel initramfs. Usage: scanary_report <log> [<log>...]
#
# Emits the pre-registration verdict inputs in one screen: selftest/probe
# health, window length, HIT_APPEAR counts split by inj (0 = real external
# candidate, 1 = instrument injection; analysis always excludes inj=1),
# region split (stack vs decoy), rate, and START/EXIT raw lines.
# A zero-hit report carries probe_ok/passes (detection-floor denominator) per
# docs/SIGSEGV/10_MEASUREMENT_PROTOCOL.md sections 3/10 -- zero without
# liveness evidence is not a verdict.
for L in "$@"; do
    [ -f "$L" ] || { echo "== missing: $L =="; continue; }
    awk '
        function val(line, key,   i, n, f, k) {
            n = split(line, f, " ")
            for (i = 1; i <= n; i++) {
                k = f[i]
                sub(/=.*/, "", k)
                if (k == key) { sub(/^[^=]*=/, "", f[i]); return f[i] }
            }
            return ""
        }
        /^EV / {
            ts = $2 + 0; kind = $3
            if (FIRST == "") FIRST = ts
            LAST = ts
            K[kind]++
            if (kind == "HIT_APPEAR") {
                inj = val($0, "inj"); reg = val($0, "region")
                AP[inj "/" reg]++
                if (inj == 0) { REAL++; if (reg == "decoy") DECOY++ }
            } else if (kind == "HIT_REWRITE") { RW++ }
            else if (kind == "PROBE") { if (val($0, "ok") == "1") POK++; else PBAD++ }
            else if (kind == "SELFTEST_FAIL") { STF++ }
            else if (kind == "SELFTEST_PASS") { STP++ }
            else if (kind == "STAT") { LASTSTAT = $0 }
            else if (kind == "EXIT") { LASTEXIT = $0 }
            else if (kind == "START") { STARTLN = $0 }
        }
        END {
            w = (LAST - FIRST) / 1000000
            printf "== %s ==\n", FILENAME
            printf "window_s=%.1f  ev_lines=%d\n", w, NR
            printf "START: %s\n", STARTLN
            printf "selftest_pass=%d selftest_fail=%d probe_ok=%d probe_bad=%d\n", STP + 0, STF + 0, POK + 0, PBAD + 0
            printf "HIT_APPEAR real(inj=0): total=%d stack=%d decoy=%d | injected(inj=1): %d\n", REAL + 0, AP["0/stack"] + 0, DECOY + 0, AP["1/stack"] + AP["1/decoy"] + 0
            if (w > 0) printf "rate_real_per_min=%.2f  (N=%d; N<10 => no rate inference, 10-protocol s3)\n", (REAL + 0) * 60 / w, REAL + 0
            printf "HIT_REWRITE=%d\n", RW + 0
            printf "STAT: %s\n", LASTSTAT
            printf "EXIT: %s\n", LASTEXIT
            if (STP + 0 == 0) printf "VERDICT_INPUT: no SELFTEST_PASS -> instrument INVALID this window\n"
            if (STF + 0 > 0) printf "VERDICT_INPUT: SELFTEST_FAIL -> instrument INVALID this window\n"
            if (PBAD + 0 > 0) printf "VERDICT_INPUT: probe_bad>0 -> degraded, keep only probe-clean span\n"
            if (LASTEXIT == "") printf "VERDICT_INPUT: no EXIT line -> truncated window, not a complete observation\n"
            if (DECOY + 0 > 0) printf "VERDICT_INPUT: decoy region inj=0 hit -> report immediately (writer hits arbitrary user pages)\n"
        }
    ' "$L"
done
