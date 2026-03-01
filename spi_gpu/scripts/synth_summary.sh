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

    # Print the per-module stat from the check stage.
    # Look for the last "=== gpu_top ===" section (from stat -top gpu_top -hierarchy).
    # This shows cells and submodules per module in the hierarchy.
    HIER_LINE=$(grep -n '=== design hierarchy ===' "$YOSYS_LOG" | tail -1 | cut -d: -f1)
    if [ -n "$HIER_LINE" ]; then
        echo ""
        echo "Per-module cell hierarchy (from final stat -hierarchy):"
        echo "---"
        # Extract from "=== design hierarchy ===" to the next blank line
        tail -n +"$HIER_LINE" "$YOSYS_LOG" \
            | sed 's/^\[[0-9.]*\] //' \
            | awk '/^$/ && seen {exit} /^[0-9]/ {exit} {if (NR>1) seen=1; print}'
    fi
} | tee "$OUTPUT_FILE"
