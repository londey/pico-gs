#!/bin/bash
# Generate a human-readable synthesis profiling summary.
#
# Usage: synth_summary.sh <yosys_log> <rss_csv> <output_file>
#
# Parses Yosys log (with -t timestamps) for stage boundaries and stat cell counts.
# Parses RSS CSV for per-stage peak memory.
# Prints a summary table to stdout and writes it to <output_file>.

set -u

YOSYS_LOG="$1"
RSS_CSV="$2"
OUTPUT_FILE="$3"

# Ordered stage names matching synth_profile.ys markers.
STAGES=("begin" "coarse" "map_ram" "map_ffram" "map_gates" "map_ffs" "map_luts (abc9)" "map_cells" "autoname" "check" "write_json")

# --- Parse stage timestamps from Yosys log ---
# With -t flag, timestamps are seconds since start: [SSSSS.SSSSSS]
# Lines look like: [00042.123456] === STAGE: begin ===
declare -A STAGE_TS

while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9]+\.[0-9]+)\].*===\ STAGE:\ (.+)\ === ]]; then
        ts="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        STAGE_TS["$name"]="$ts"
    fi
done < "$YOSYS_LOG"

# Convert SSSSS.SSSSSS to integer seconds (strip leading zeros for bash arithmetic)
ts_to_secs() {
    local ts="$1"
    local int="${ts%%.*}"
    echo "$((10#$int))"
}

# --- Parse per-stage cell counts from Yosys log ---
# stat output uses format: "       264 cells" (leading whitespace, number, " cells")
# We take the LAST "N cells" line before each new STAGE marker.
declare -A STAGE_CELLS
current_stage=""
last_cells=""

while IFS= read -r line; do
    if [[ "$line" =~ ===\ STAGE:\ (.+)\ === ]]; then
        # Save the accumulated cells for the previous stage
        if [[ -n "$current_stage" && -n "$last_cells" ]]; then
            STAGE_CELLS["$current_stage"]="$last_cells"
        fi
        current_stage="${BASH_REMATCH[1]}"
        last_cells=""
    elif [[ "$line" =~ [[:space:]]+([0-9]+)[[:space:]]+cells$ ]]; then
        last_cells="${BASH_REMATCH[1]}"
    fi
done < "$YOSYS_LOG"
# Save cells for the final stage
if [[ -n "$current_stage" && -n "$last_cells" ]]; then
    STAGE_CELLS["$current_stage"]="$last_cells"
fi

# --- Parse per-stage peak RSS from CSV ---
declare -A STAGE_PEAK_RSS

if [ -f "$RSS_CSV" ]; then
    while IFS=, read -r elapsed rss stage; do
        [ "$elapsed" = "elapsed_s" ] && continue
        rss_num=$((10#$rss + 0)) 2>/dev/null || continue
        current_peak=${STAGE_PEAK_RSS["$stage"]:-0}
        if [ "$rss_num" -gt "$current_peak" ]; then
            STAGE_PEAK_RSS["$stage"]=$rss_num
        fi
    done < "$RSS_CSV"
fi

# --- Build summary table ---
{
    echo "==========================================================================="
    echo "  Yosys Synthesis Memory Profile"
    echo "==========================================================================="
    printf "%-20s %10s %12s %12s\n" "Stage" "Duration" "Peak RSS" "Cells"
    printf "%-20s %10s %12s %12s\n" "-------------------" "--------" "----------" "----------"

    OVERALL_PEAK_RSS=0
    OVERALL_PEAK_STAGE=""

    for i in "${!STAGES[@]}"; do
        stage="${STAGES[$i]}"

        # Duration: time from this stage to the next stage
        start_ts="${STAGE_TS[$stage]:-}"
        if [ "$((i + 1))" -lt "${#STAGES[@]}" ]; then
            next_stage="${STAGES[$((i + 1))]}"
            end_ts="${STAGE_TS[$next_stage]:-}"
        else
            end_ts="${STAGE_TS[done]:-}"
        fi

        if [ -n "$start_ts" ] && [ -n "$end_ts" ]; then
            start_s=$(ts_to_secs "$start_ts")
            end_s=$(ts_to_secs "$end_ts")
            dur=$((end_s - start_s))
            if [ "$dur" -ge 60 ]; then
                dur_str="$((dur / 60))m $((dur % 60))s"
            else
                dur_str="${dur}s"
            fi
        else
            dur_str="-"
        fi

        # Peak RSS for this stage
        peak_rss=${STAGE_PEAK_RSS[$stage]:-0}
        if [ "$peak_rss" -gt 0 ]; then
            peak_mb=$((peak_rss / 1024))
            rss_str="${peak_mb} MB"
        else
            rss_str="-"
        fi

        if [ "$peak_rss" -gt "$OVERALL_PEAK_RSS" ]; then
            OVERALL_PEAK_RSS=$peak_rss
            OVERALL_PEAK_STAGE="$stage"
        fi

        # Cell count after this stage
        cells="${STAGE_CELLS[$stage]:-"-"}"

        printf "%-20s %10s %12s %12s\n" "$stage" "$dur_str" "$rss_str" "$cells"
    done

    echo "==========================================================================="
    if [ "$OVERALL_PEAK_RSS" -gt 0 ]; then
        peak_gb=$(awk "BEGIN {printf \"%.1f\", $OVERALL_PEAK_RSS / 1048576}")
        echo "  Peak RSS: ${peak_gb} GiB during '${OVERALL_PEAK_STAGE}'"
    else
        echo "  Peak RSS: (no data -- monitor may not have captured readings)"
    fi
    echo "==========================================================================="

    # --- FPGA Resource Breakdown ---
    # Parse pre-flatten per-module stats (between first "Printing statistics" and
    # "=== STAGE: coarse ===") for $mul, $div, and memory bits per module.
    # Parse memory mapping decisions from map_ram stage.
    # Parse post-synthesis MULT18X18D and DP16KD totals.

    echo ""
    echo "==========================================================================="
    echo "  FPGA Resource Breakdown"
    echo "==========================================================================="

    # Extract post-synthesis MULT18X18D and DP16KD counts from the last stat output.
    # Use the last occurrence of each cell type count in the log.
    MULT_COUNT=$(grep -oP '\d+(?=\s+MULT18X18D)' "$YOSYS_LOG" | tail -1)
    BRAM_COUNT=$(grep -oP '\d+(?=\s+DP16KD)' "$YOSYS_LOG" | tail -1)
    MULT_COUNT=${MULT_COUNT:-0}
    BRAM_COUNT=${BRAM_COUNT:-0}

    echo ""
    printf "  Post-synthesis totals (ECP5-25K):\n"
    printf "    MULT18X18D:  %4d / %4d   (%3d%%)\n" "$MULT_COUNT" 28 "$((MULT_COUNT * 100 / 28))"
    printf "    DP16KD:      %4d / %4d   (%3d%%)\n" "$BRAM_COUNT" 56 "$((BRAM_COUNT * 100 / 56))"

    # Parse per-module $mul, $div, and memory bits from the pre-flatten stat
    # output. This section runs between the first "Printing statistics" line
    # and the "=== STAGE: coarse ===" marker.
    echo ""
    echo "  Per-module multiplier sources (pre-flatten RTL):"
    echo ""

    # Use awk to parse module sections and extract $mul, $div, memory bits.
    # Only process lines between "Printing statistics" and "STAGE: coarse".
    awk '
    # Strip Yosys timestamp prefix: [00000.618070]
    { sub(/^\[[0-9]+\.[0-9]+\] /, "") }

    /Printing statistics/ && !done_stats { in_stats = 1; next }
    /=== STAGE: coarse ===/ { in_stats = 0; done_stats = 1 }

    !in_stats { next }

    # Module header: === module_name ===
    /^=== .+ ===$/ {
        mod = $0
        gsub(/^=== | ===$/, "", mod)
        in_local = 0
        next
    }

    # Only parse cell counts from "Local Count, excluding submodules" sections.
    # This avoids double-counting from the "including submodules" totals.
    /Local Count, excluding submodules/ { in_local = 1; next }
    /Count including submodules/ { in_local = 0; next }

    !in_local { next }

    # Cell counts: leading whitespace, number, cell type.
    # Field layout after timestamp strip: "        112   $mul" → $1=count, $2=type
    /\$mul$/ && mod != "" {
        for (i = 1; i <= NF; i++) if ($i == "$mul" && $(i-1)+0 > 0) mul[mod] = $(i-1)+0
    }
    /\$div$/ && mod != "" {
        for (i = 1; i <= NF; i++) if ($i == "$div" && $(i-1)+0 > 0) div[mod] = $(i-1)+0
    }
    /memory bits$/ && mod != "" {
        for (i = 1; i <= NF; i++) if ($i == "memory" && $(i+1) == "bits" && $(i-1)+0 > 0) mem[mod] = $(i-1)+0
    }

    END {
        # Collect modules that have any of mul, div, or mem
        n = 0
        for (m in mul)  { if (!(m in seen)) { mods[n++] = m; seen[m] = 1 } }
        for (m in div)  { if (!(m in seen)) { mods[n++] = m; seen[m] = 1 } }
        for (m in mem)  { if (!(m in seen)) { mods[n++] = m; seen[m] = 1 } }

        # Sort by $mul count descending, then $div, then mem (insertion sort)
        for (i = 1; i < n; i++) {
            key = mods[i]
            km = (key in mul) ? mul[key] : 0
            kd = (key in div) ? div[key] : 0
            kb = (key in mem) ? mem[key] : 0
            j = i - 1
            while (j >= 0) {
                jm = (mods[j] in mul) ? mul[mods[j]] : 0
                jd = (mods[j] in div) ? div[mods[j]] : 0
                jb = (mods[j] in mem) ? mem[mods[j]] : 0
                if (jm < km || (jm == km && jd < kd) || (jm == km && jd == kd && jb < kb)) {
                    mods[j+1] = mods[j]
                    j--
                } else break
            }
            mods[j+1] = key
        }

        # Shorten $paramod names: "$paramod$hash\name" → "name"
        for (i = 0; i < n; i++) {
            orig = mods[i]
            if (index(orig, "$paramod") == 1) {
                short = orig
                sub(/.*\\/, "", short)
                mods[i] = short
                if (orig in mul) { mul[short] = mul[orig]; delete mul[orig] }
                if (orig in div) { div[short] = div[orig]; delete div[orig] }
                if (orig in mem) { mem[short] = mem[orig]; delete mem[orig] }
            }
        }

        printf "    %-26s %5s  %5s  %10s\n", "Module", "$mul", "$div", "Mem bits"
        printf "    %-26s %5s  %5s  %10s\n", "--------------------------", "-----", "-----", "----------"

        total_mul = 0; total_div = 0; total_mem = 0
        for (i = 0; i < n; i++) {
            m = mods[i]
            vm = (m in mul) ? mul[m] : 0
            vd = (m in div) ? div[m] : 0
            vb = (m in mem) ? mem[m] : 0
            total_mul += vm; total_div += vd; total_mem += vb
            ms = (vm > 0) ? sprintf("%d", vm) : "-"
            ds = (vd > 0) ? sprintf("%d", vd) : "-"
            bs = (vb > 0) ? sprintf("%d", vb) : "-"
            printf "    %-26s %5s  %5s  %10s\n", m, ms, ds, bs
        }
        printf "    %-26s %5s  %5s  %10s\n", "--------------------------", "-----", "-----", "----------"
        printf "    %-26s %5d  %5d  %10d\n", "TOTAL", total_mul, total_div, total_mem
    }
    ' "$YOSYS_LOG"

    # Parse memory mapping decisions from the map_ram stage.
    # Lines look like: mapping memory gpu_top.u_display_ctrl...mem via $__DP16KD_
    echo ""
    echo "  Memory mapping decisions:"
    echo ""
    grep 'mapping memory' "$YOSYS_LOG" \
        | sed 's/^\[[0-9.]*\] //' \
        | while IFS= read -r line; do
            # Extract: "mapping memory <path> via <target>"
            mem_path=$(echo "$line" | sed 's/mapping memory //;s/ via .*//')
            mem_target=$(echo "$line" | sed 's/.* via //')
            # Shorten gpu_top. prefix
            mem_path=${mem_path#gpu_top.}
            # Classify as block RAM or distributed RAM
            case "$mem_target" in
                *DP16KD*|*PDPW16KD*) ram_type="block RAM" ;;
                *DPR16X4*|*TRELLIS*) ram_type="distributed RAM" ;;
                *) ram_type="$mem_target" ;;
            esac
            printf "    %-45s → %s (%s)\n" "$mem_path" "$mem_target" "$ram_type"
        done

    echo ""
    echo "==========================================================================="
} | tee "$OUTPUT_FILE"
