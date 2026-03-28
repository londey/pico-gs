#!/bin/bash
# Generate a per-module ECP5 resource utilization report.
#
# Usage: resource_report.sh <yosys_log> <output_file>
#
# Parses Yosys stat output from a -noflatten synthesis run to extract
# per-module ECP5 primitive counts (LUT4, TRELLIS_FF, CCU2C, DP16KD,
# MULT18X18D, PDPW16KD).
#
# Parameterised module names ($paramod$hash\name) are shortened and
# their counts summed.

set -u

YOSYS_LOG="$1"
OUTPUT_FILE="$2"

# ECP5-25K resource limits.
LUT4_LIMIT=24288
FF_LIMIT=24288
CCU2C_LIMIT=12144
DP16KD_LIMIT=56
MULT18_LIMIT=28

{
    echo "==========================================================================="
    echo "  Per-Module ECP5 Resource Utilization (noflatten estimate)"
    echo "==========================================================================="

    awk '
    # Strip Yosys timestamp prefix: [00000.618070]
    { sub(/^\[[0-9]+\.[0-9]+\] /, "") }

    # Module header: === module_name ===
    /^=== .+ ===$/ {
        mod = $0
        gsub(/^=== | ===$/, "", mod)
        # Skip "design hierarchy" summary section (different format).
        if (mod == "design hierarchy") { mod = ""; next }
        # Shorten $paramod names: "$paramod$hash\name" -> "name"
        if (index(mod, "$paramod") == 1) sub(/.*\\/, "", mod)
        next
    }

    # Stop parsing at the "Count including submodules" grand total.
    /Count including submodules/ { mod = "" }

    # Cell count lines.  Yosys stat format:
    #   "        52   LUT4"
    # Match lines with a known ECP5 primitive name.
    mod != "" {
        for (i = 1; i <= NF; i++) {
            if ($i == "LUT4" || $i == "TRELLIS_FF" || $i == "CCU2C" ||
                $i == "DP16KD" || $i == "MULT18X18D" || $i == "PDPW16KD") {
                # Count is the adjacent numeric field.
                count = 0
                if (i < NF && $(i+1)+0 > 0) count = $(i+1)+0
                else if (i > 1 && $(i-1)+0 > 0) count = $(i-1)+0
                if (count > 0) {
                    cells[mod, $i] += count
                    if (!(mod in seen)) { mods[n++] = mod; seen[mod] = 1 }
                }
            }
        }
    }

    END {
        # Sort modules by LUT4 descending (insertion sort).
        for (i = 1; i < n; i++) {
            key = mods[i]
            kv = (key SUBSEP "LUT4") in cells ? cells[key, "LUT4"] : 0
            j = i - 1
            while (j >= 0) {
                jv = (mods[j] SUBSEP "LUT4") in cells ? cells[mods[j], "LUT4"] : 0
                if (jv < kv) { mods[j+1] = mods[j]; j-- }
                else break
            }
            mods[j+1] = key
        }

        # Header.
        fmt = "  %-28s %6s %8s %6s %7s %7s %7s\n"
        sep = "  ----------------------------  -----  -------  -----  ------  ------  ------"
        printf fmt, "Module", "LUT4", "TRLS_FF", "CCU2C", "DP16KD", "MULT18", "PDPW16"
        print sep

        # Per-module rows.
        tot_lut = 0; tot_ff = 0; tot_ccu = 0; tot_dp = 0; tot_mul = 0; tot_pdp = 0
        for (i = 0; i < n; i++) {
            m = mods[i]
            vl = ((m, "LUT4")       in cells) ? cells[m, "LUT4"]       : 0
            vf = ((m, "TRELLIS_FF") in cells) ? cells[m, "TRELLIS_FF"] : 0
            vc = ((m, "CCU2C")      in cells) ? cells[m, "CCU2C"]      : 0
            vd = ((m, "DP16KD")     in cells) ? cells[m, "DP16KD"]     : 0
            vm = ((m, "MULT18X18D") in cells) ? cells[m, "MULT18X18D"] : 0
            vp = ((m, "PDPW16KD")   in cells) ? cells[m, "PDPW16KD"]  : 0

            # Skip modules with zero resources (e.g. packages).
            if (vl + vf + vc + vd + vm + vp == 0) continue

            tot_lut += vl; tot_ff += vf; tot_ccu += vc
            tot_dp  += vd; tot_mul += vm; tot_pdp += vp

            sl = vl > 0 ? sprintf("%d", vl) : "-"
            sf = vf > 0 ? sprintf("%d", vf) : "-"
            sc = vc > 0 ? sprintf("%d", vc) : "-"
            sd = vd > 0 ? sprintf("%d", vd) : "-"
            sm = vm > 0 ? sprintf("%d", vm) : "-"
            sp = vp > 0 ? sprintf("%d", vp) : "-"

            printf fmt, m, sl, sf, sc, sd, sm, sp
        }

        # Totals and utilization.
        print sep
        printf fmt, "TOTAL", tot_lut, tot_ff, tot_ccu, tot_dp, tot_mul, tot_pdp

        lut_lim  = '"$LUT4_LIMIT"'
        ff_lim   = '"$FF_LIMIT"'
        ccu_lim  = '"$CCU2C_LIMIT"'
        dp_lim   = '"$DP16KD_LIMIT"'
        mul_lim  = '"$MULT18_LIMIT"'

        printf fmt, "ECP5-25K", lut_lim, ff_lim, ccu_lim, dp_lim, mul_lim, "*" dp_lim

        ul = (tot_lut > 0) ? sprintf("%d%%", tot_lut * 100 / lut_lim) : "-"
        uf = (tot_ff  > 0) ? sprintf("%d%%", tot_ff  * 100 / ff_lim)  : "-"
        uc = (tot_ccu > 0) ? sprintf("%d%%", tot_ccu * 100 / ccu_lim) : "-"
        bram_total = tot_dp + tot_pdp
        ud = (bram_total > 0) ? sprintf("%d%%", bram_total * 100 / dp_lim) : "-"
        um = (tot_mul > 0) ? sprintf("%d%%", tot_mul * 100 / mul_lim) : "-"

        printf fmt, "Utilization", ul, uf, uc, ud, um, ""
    }
    ' "$YOSYS_LOG"

    echo "  ----------------------------  -----  -------  -----  ------  ------  ------"
    echo "  * PDPW16KD shares physical block RAM with DP16KD (56 total)"
    echo "==========================================================================="
} | tee "$OUTPUT_FILE"
