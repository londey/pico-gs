#!/bin/bash
# Generate a per-module ECP5 resource utilization report.
#
# Usage: resource_report.sh <yosys_log> <output_file>
#
# Parses Yosys stat output from a -noflatten synthesis run to extract
# per-module ECP5 primitive counts (LUT4, TRELLIS_FF, CCU2C, DP16KD,
# MULT18X18D, PDPW16KD) and instance counts from submodule listings.
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
        if (mod == "design hierarchy") { mod = ""; next }
        # Shorten $paramod names: "$paramod$hash\name" -> "name"
        if (index(mod, "$paramod") == 1) sub(/.*\\/, "", mod)
        next
    }

    # Stop parsing at the "Count including submodules" grand total.
    /Count including submodules/ { mod = "" }

    # Cell/submodule count lines within a module section.
    # Yosys stat format: "        52   LUT4" or "         4   zbuf_tag_bram"
    mod != "" {
        for (i = 1; i <= NF; i++) {
            if ($i == "LUT4" || $i == "TRELLIS_FF" || $i == "CCU2C" ||
                $i == "DP16KD" || $i == "MULT18X18D" || $i == "PDPW16KD") {
                # ECP5 primitive — record resource count.
                count = 0
                if (i < NF && $(i+1)+0 > 0) count = $(i+1)+0
                else if (i > 1 && $(i-1)+0 > 0) count = $(i-1)+0
                if (count > 0) {
                    cells[mod, $i] += count
                    if (!(mod in seen)) { mods[n++] = mod; seen[mod] = 1 }
                }
            }
        }

        # Detect submodule instantiation lines: "  <count>   <name>"
        # These appear after "N submodules" and list both ECP5 primitives
        # and child module names.  Skip known primitives and wire/port
        # keywords; anything else is a child module instantiation.
        if (NF == 2) {
            cnt = $1 + 0
            name = $2
            if (cnt > 0 && name !~ /^(LUT4|TRELLIS_FF|TRELLIS_DPR16X4|CCU2C|DP16KD|MULT18X18D|PDPW16KD|EHXPLLL|\$_TBUF_|wires|wire|public|ports|port|cells|submodules|memories|memory|processes)$/) {
                # Shorten $paramod child names too.
                if (index(name, "$paramod") == 1) sub(/.*\\/, "", name)
                # Record: parent "mod" has "cnt" instances of child "name".
                # Use comma-separated key; accumulate for parameterised merges.
                child_key = mod SUBSEP name
                children[child_key] += cnt
                # Track which children each parent has.
                if (!(child_key in child_seen)) {
                    child_seen[child_key] = 1
                    child_list[mod, ++child_n[mod]] = name
                }
            }
        }
    }

    # Recursive function to compute total instances from the top module.
    function compute_instances(parent, parent_count,    i, child, cnt) {
        for (i = 1; i <= child_n[parent]; i++) {
            child = child_list[parent, i]
            cnt = children[parent, child] * parent_count
            total_inst[child] += cnt
            compute_instances(child, cnt)
        }
    }

    END {
        # Walk instantiation tree from gpu_top (1 instance of top).
        total_inst["gpu_top"] = 1
        compute_instances("gpu_top", 1)

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
        fmt  = "  %-28s %4s %6s %8s %6s %7s %7s %7s\n"
        sep  = "  ----------------------------  ---  -----  -------  -----  ------  ------  ------"
        printf fmt, "Module", "Inst", "LUT4", "TRLS_FF", "CCU2C", "DP16KD", "MULT18", "PDPW16"
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

            # Instance count from hierarchy walk (default 1 if not found).
            ic = (m in total_inst) ? total_inst[m] : 1

            tot_lut += vl * ic; tot_ff += vf * ic; tot_ccu += vc * ic
            tot_dp  += vd * ic; tot_mul += vm * ic; tot_pdp += vp * ic

            sl = vl > 0 ? sprintf("%d", vl) : "-"
            sf = vf > 0 ? sprintf("%d", vf) : "-"
            sc = vc > 0 ? sprintf("%d", vc) : "-"
            sd = vd > 0 ? sprintf("%d", vd) : "-"
            sm = vm > 0 ? sprintf("%d", vm) : "-"
            sp = vp > 0 ? sprintf("%d", vp) : "-"

            # Show "xN" when N > 1.
            si = (ic > 1) ? sprintf("x%d", ic) : ""

            printf fmt, m, si, sl, sf, sc, sd, sm, sp
        }

        # Totals and utilization.
        print sep
        printf fmt, "TOTAL", "", tot_lut, tot_ff, tot_ccu, tot_dp, tot_mul, tot_pdp

        lut_lim  = '"$LUT4_LIMIT"'
        ff_lim   = '"$FF_LIMIT"'
        ccu_lim  = '"$CCU2C_LIMIT"'
        dp_lim   = '"$DP16KD_LIMIT"'
        mul_lim  = '"$MULT18_LIMIT"'

        printf fmt, "ECP5-25K", "", lut_lim, ff_lim, ccu_lim, dp_lim, mul_lim, "*" dp_lim

        ul = (tot_lut > 0) ? sprintf("%d%%", tot_lut * 100 / lut_lim) : "-"
        uf = (tot_ff  > 0) ? sprintf("%d%%", tot_ff  * 100 / ff_lim)  : "-"
        uc = (tot_ccu > 0) ? sprintf("%d%%", tot_ccu * 100 / ccu_lim) : "-"
        bram_total = tot_dp + tot_pdp
        ud = (bram_total > 0) ? sprintf("%d%%", bram_total * 100 / dp_lim) : "-"
        um = (tot_mul > 0) ? sprintf("%d%%", tot_mul * 100 / mul_lim) : "-"

        printf fmt, "Utilization", "", ul, uf, uc, ud, um, ""
    }
    ' "$YOSYS_LOG"

    echo "  ----------------------------  ---  -----  -------  -----  ------  ------  ------"
    echo "  * PDPW16KD shares physical block RAM with DP16KD (56 total)"
    echo "  * Inst column shows instance count; TOTAL reflects per-module x instances"
    echo "==========================================================================="
} | tee "$OUTPUT_FILE"
