#!/bin/bash
# Monitor RSS (resident set size) of a process, correlating with Yosys synthesis stages.
#
# Usage: rss_monitor.sh <pid> <output_csv> <yosys_log>
#
# Polls /proc/<pid>/status for VmRSS every second.
# Detects synthesis stage transitions by tailing the Yosys log for
# "=== STAGE:" markers.
# Writes CSV: elapsed_s,rss_kb,stage

set -u

PID="$1"
OUTPUT_CSV="$2"
YOSYS_LOG="$3"

echo "elapsed_s,rss_kb,stage" > "$OUTPUT_CSV"

START_EPOCH=$(date +%s)
CURRENT_STAGE="startup"
LAST_LOG_BYTES=0

while kill -0 "$PID" 2>/dev/null; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_EPOCH))

    # Read VmRSS from /proc (in kB)
    RSS_KB=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null) || true
    if [ -z "$RSS_KB" ]; then
        sleep 1
        continue
    fi

    # Check Yosys log for new stage markers (only scan new bytes)
    if [ -f "$YOSYS_LOG" ]; then
        CUR_SIZE=$(stat -c%s "$YOSYS_LOG" 2>/dev/null) || CUR_SIZE=0
        if [ "$CUR_SIZE" -gt "$LAST_LOG_BYTES" ]; then
            NEW_STAGE=$(tail -c +"$((LAST_LOG_BYTES + 1))" "$YOSYS_LOG" 2>/dev/null \
                | sed -n 's/.*=== STAGE: \([^=]*\) ===/\1/p' \
                | tail -1 \
                | sed 's/ *$//')
            if [ -n "$NEW_STAGE" ] && [ "$NEW_STAGE" != "done" ]; then
                CURRENT_STAGE="$NEW_STAGE"
                RSS_MB=$((RSS_KB / 1024))
                echo "[synth] ${CURRENT_STAGE}  (RSS: ${RSS_MB} MB)" >&2
            fi
            LAST_LOG_BYTES=$CUR_SIZE
        fi
    fi

    echo "${ELAPSED},${RSS_KB},${CURRENT_STAGE}" >> "$OUTPUT_CSV"
    sleep 1
done
