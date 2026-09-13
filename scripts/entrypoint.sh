#!/bin/bash
# entrypoint.sh — OSM PBF to GeoParquet conversion via DuckDB
# Usage: ./scripts/entrypoint.sh <input.osm.pbf> <output.places.parquet> [country_code]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INPUT_PBF="$1"
OUTPUT_PARQUET="$2"
COUNTRY_CODE="${3:-}"

if [ -z "$INPUT_PBF" ] || [ -z "$OUTPUT_PARQUET" ]; then
    echo "****************************************************************"
    echo " ERROR: Missing required arguments."
    echo ""
    echo " Usage:  ./scripts/entrypoint.sh <input.osm.pbf> <output.places.parquet> [country_code]"
    echo "****************************************************************"
    exit 1
fi

if [ ! -f "$INPUT_PBF" ]; then
    echo "****************************************************************"
    echo " ERROR: Input PBF file not found: $INPUT_PBF"
    echo "****************************************************************"
    exit 1
fi

echo "[INFO] Input  : $INPUT_PBF ($(du -sh "$INPUT_PBF" | cut -f1))"
echo "[INFO] Output : $OUTPUT_PARQUET"
echo "[INFO] Country: ${COUNTRY_CODE:-unknown}"
START_TIME=$(date +%s)

TMP_FIFO=$(mktemp -u /tmp/osm_export_XXXXXX.jsonl)
TMP_SQL=$(mktemp /tmp/export_XXXXXX.sql)
TMP_DIR=$(mktemp -d /tmp/duckdb_spill_XXXXXX)
mkfifo "$TMP_FIFO"

get_rss_kb() {
    local target_pid="$1"
    if [ -z "$target_pid" ] || [ ! -d "/proc/$target_pid" ]; then
        echo 0
        return
    fi
    local total=0
    local self_rss
    self_rss=$(awk '/VmRSS:/ {print $2}' "/proc/$target_pid/status" 2>/dev/null || echo 0)
    total=$((total + ${self_rss:-0}))

    # Inspect direct children (e.g. for subshells like osmium export | tr)
    local children=""
    if [ -f "/proc/$target_pid/task/$target_pid/children" ]; then
        children=$(cat "/proc/$target_pid/task/$target_pid/children" 2>/dev/null || true)
    fi
    if [ -z "$children" ] && command -v pgrep >/dev/null 2>&1; then
        children=$(pgrep -P "$target_pid" 2>/dev/null || true)
    fi

    for cpid in $children; do
        if [ -d "/proc/$cpid" ]; then
            local crss
            crss=$(awk '/VmRSS:/ {print $2}' "/proc/$cpid/status" 2>/dev/null || echo 0)
            total=$((total + ${crss:-0}))
        fi
    done

    # Fallback to ps if /proc yielded 0 and ps binary is present
    if [ "$total" -le 0 ] && command -v ps >/dev/null 2>&1; then
        local raw_ps
        raw_ps=$(ps -o rss= -p "$target_pid" 2>/dev/null | tr -d ' \t\n')
        total=${raw_ps:-0}
    fi

    echo "$total"
}

format_mem() {
    local kb="$1"
    if [ -z "$kb" ] || [ "$kb" -le 0 ] 2>/dev/null; then
        echo "0.0 MB"
    elif [ "$kb" -gt 1048576 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.2f GB\", $kb/1048576}"
    else
        awk "BEGIN {printf \"%.1f MB\", $kb/1024}"
    fi
}

stop_monitor() {
    if [ -n "${MONITOR_PID:-}" ]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        if [ -f "/proc/$MONITOR_PID/task/$MONITOR_PID/children" ]; then
            for cpid in $(cat "/proc/$MONITOR_PID/task/$MONITOR_PID/children" 2>/dev/null || true); do
                kill "$cpid" 2>/dev/null || true
            done
        fi
        if command -v pkill >/dev/null 2>&1; then
            pkill -P "$MONITOR_PID" 2>/dev/null || true
        fi
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

cleanup() {
    stop_monitor
    kill "$DUCKDB_PID" "$OSMIUM_PID" 2>/dev/null || true
    rm -rf "$TMP_FIFO" "$TMP_SQL" "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# Background heartbeat monitor for observability
monitor_resources() {
    set +e
    local duck_pid="$1"
    local osm_pid="$2"
    local m_start
    m_start=$(date +%s)
    local sleep_pid=""

    cleanup_monitor() {
        if [ -n "$sleep_pid" ]; then
            kill "$sleep_pid" 2>/dev/null || true
            wait "$sleep_pid" 2>/dev/null || true
        fi
        exit 0
    }
    trap cleanup_monitor TERM INT EXIT

    while kill -0 "$duck_pid" 2>/dev/null || kill -0 "$osm_pid" 2>/dev/null; do
        sleep 15 &
        sleep_pid=$!
        wait "$sleep_pid" 2>/dev/null || true
        sleep_pid=""

        if ! kill -0 "$duck_pid" 2>/dev/null && ! kill -0 "$osm_pid" 2>/dev/null; then
            break
        fi

        local now
        now=$(date +%s)
        local elapsed=$((now - m_start))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))

        local duck_rss="0.0 MB"
        local osm_rss="0.0 MB"

        if [ -n "$duck_pid" ] && kill -0 "$duck_pid" 2>/dev/null; then
            local raw_duck
            raw_duck=$(get_rss_kb "$duck_pid")
            duck_rss=$(format_mem "$raw_duck")
        elif [ -n "$duck_pid" ]; then
            duck_rss="done"
        fi

        if [ -n "$osm_pid" ] && kill -0 "$osm_pid" 2>/dev/null; then
            local raw_osm
            raw_osm=$(get_rss_kb "$osm_pid")
            osm_rss=$(format_mem "$raw_osm")
        elif [ -n "$osm_pid" ]; then
            osm_rss="done"
        fi

        local mem_avail
        mem_avail=$(awk '/MemAvailable/ {printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null || echo "N/A")
        local disk_free
        disk_free=$(df -h "$TMP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A")

        echo "[HEARTBEAT $(printf "%02d:%02d" $mins $secs)] DuckDB RSS: $duck_rss | Osmium RSS: $osm_rss | SysMemAvail: $mem_avail | DiskFree: $disk_free"
    done
}

BUILD_VERSION="${BUILD_VERSION:-${BUILD_BUILDNUMBER:-${BUILD_NUMBER:-$(git describe --tags --always 2>/dev/null || echo "dev")}}}"
EXPORT_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "[STAGE 1/3] Streaming Osmium export through named pipe directly into DuckDB..."
(set -o pipefail; osmium export "$INPUT_PBF" --geometry-types=point,polygon --attributes=type,id,version,timestamp --output-format=geojsonseq | tr -d '\036' > "$TMP_FIFO") &
OSMIUM_PID=$!

sed \
  -e "s|__INPUT_JSONL__|${TMP_FIFO}|g" \
  -e "s|__OUTPUT_PARQUET__|${OUTPUT_PARQUET}|g" \
  -e "s|__COUNTRY_CODE__|${COUNTRY_CODE}|g" \
  -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  -e "s|__BUILD_VERSION__|${BUILD_VERSION}|g" \
  -e "s|__EXPORT_TIMESTAMP__|${EXPORT_TIMESTAMP}|g" \
  -e "s|__TEMP_DIR__|${TMP_DIR}|g" \
  "$SCRIPT_DIR/export_pois.sql" > "$TMP_SQL"

duckdb -dark-mode -no-stdin -c ".read $TMP_SQL" &
DUCKDB_PID=$!

monitor_resources "$DUCKDB_PID" "$OSMIUM_PID" &
MONITOR_PID=$!

wait "$DUCKDB_PID"
DUCKDB_EXIT=$?
stop_monitor

wait "$OSMIUM_PID"
OSMIUM_EXIT=$?

cleanup
trap - EXIT INT TERM

if [ $DUCKDB_EXIT -ne 0 ]; then
    if [ $DUCKDB_EXIT -eq 137 ]; then
        echo "****************************************************************"
        echo " [FATAL] DuckDB was killed by SIGKILL (Exit code 137)!"
        echo " Cause: Out-Of-Memory (OOM) killer terminated the process."
        echo " Diagnostics: Memory limit exceeded the available container RAM."
        echo "****************************************************************"
    else
        echo "[FAIL] DuckDB export failed with exit code $DUCKDB_EXIT"
    fi
    exit $DUCKDB_EXIT
fi

if [ $OSMIUM_EXIT -ne 0 ]; then
    if [ $OSMIUM_EXIT -eq 137 ]; then
        echo "****************************************************************"
        echo " [FATAL] Osmium export was killed by SIGKILL (Exit code 137)!"
        echo "****************************************************************"
    else
        echo "[FAIL] Osmium export failed with exit code $OSMIUM_EXIT"
    fi
    exit $OSMIUM_EXIT
fi

echo "[STAGE 2/3] Stream conversion completed successfully."
echo "[STAGE 3/3] Validating GeoParquet output..."

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [ ! -f "$OUTPUT_PARQUET" ]; then
    echo "****************************************************************"
    echo " ERROR: Expected output file was not produced: $OUTPUT_PARQUET"
    echo "****************************************************************"
    exit 1
fi

FILE_SIZE=$(du -sh "$OUTPUT_PARQUET" | cut -f1)
POI_COUNT=$(duckdb -dark-mode -no-stdin -noheader -csv -c "SELECT count(*) FROM read_parquet('$OUTPUT_PARQUET');" 2>/dev/null | tail -n 1)
echo "[OK] Successfully exported GeoParquet: $OUTPUT_PARQUET ($FILE_SIZE, $POI_COUNT POIs) in ${ELAPSED}s"
