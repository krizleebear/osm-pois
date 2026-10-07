#!/bin/bash
# entrypoint.sh — OSM PBF to GeoParquet conversion via DuckDB
# Usage: ./scripts/entrypoint.sh <input.osm.pbf> <output.places.parquet> [country_code]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INPUT_PBF="$1"
OUTPUT_PARQUET="$2"
COUNTRY_CODE="${3:-}"
SPATIAL_FILTER="${4:-}"

if [ -z "$INPUT_PBF" ] || [ -z "$OUTPUT_PARQUET" ]; then
    echo "****************************************************************"
    echo " ERROR: Missing required arguments."
    echo ""
    echo " Usage:  ./scripts/entrypoint.sh <input.osm.pbf> <output.places.parquet> [country_code] [spatial_filter]"
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

if [ "$COUNTRY_CODE" = "US" ] && [ -z "$SPATIAL_FILTER" ]; then
    echo "[INFO] US dataset detected. Executing 3-zone spatial partitioning (West, Central, East) for bounded memory execution..."
    SPLIT_DIR=$(mktemp -d /tmp/us_partition_XXXXXX)
    trap "rm -rf '$SPLIT_DIR'" EXIT INT TERM

    echo "[INFO] [1/5] Extracting West partition (longitude < -100)..."
    osmium extract -b -180,15,-100,72 "$INPUT_PBF" -o "$SPLIT_DIR/us_west.pois.pbf" --strategy=complete_ways --overwrite

    echo "[INFO] [2/5] Extracting Central partition (-100 <= longitude < -85)..."
    osmium extract -b -100,15,-85,72 "$INPUT_PBF" -o "$SPLIT_DIR/us_central.pois.pbf" --strategy=complete_ways --overwrite

    echo "[INFO] [3/5] Extracting East partition (longitude >= -85)..."
    osmium extract -b -85,15,-65,72 "$INPUT_PBF" -o "$SPLIT_DIR/us_east.pois.pbf" --strategy=complete_ways --overwrite

    echo "[INFO] [4/5] Converting partitions to GeoParquet..."
    "$SCRIPT_DIR/entrypoint.sh" "$SPLIT_DIR/us_west.pois.pbf" "$SPLIT_DIR/us_west.places.parquet" "$COUNTRY_CODE" "AND ST_X(geometry) < -100"
    rm -f "$SPLIT_DIR/us_west.pois.pbf"

    "$SCRIPT_DIR/entrypoint.sh" "$SPLIT_DIR/us_central.pois.pbf" "$SPLIT_DIR/us_central.places.parquet" "$COUNTRY_CODE" "AND ST_X(geometry) >= -100 AND ST_X(geometry) < -85"
    rm -f "$SPLIT_DIR/us_central.pois.pbf"

    "$SCRIPT_DIR/entrypoint.sh" "$SPLIT_DIR/us_east.pois.pbf" "$SPLIT_DIR/us_east.places.parquet" "$COUNTRY_CODE" "AND ST_X(geometry) >= -85"
    rm -f "$SPLIT_DIR/us_east.pois.pbf"

    echo "[INFO] [5/5] Merging partitioned GeoParquet into $OUTPUT_PARQUET..."
    BUILD_VERSION="${BUILD_VERSION:-${BUILD_BUILDNUMBER:-${BUILD_NUMBER:-$(git describe --tags --always 2>/dev/null || echo "dev")}}}"
    EXPORT_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    duckdb -dark-mode -no-stdin -c "
    SET preserve_insertion_order = false;
    SET threads = 2;
    SET max_memory = '2000MB';
    COPY (
        SELECT * FROM read_parquet([
            '$SPLIT_DIR/us_west.places.parquet',
            '$SPLIT_DIR/us_central.places.parquet',
            '$SPLIT_DIR/us_east.places.parquet'
        ])
    ) TO '$OUTPUT_PARQUET' (
        FORMAT PARQUET,
        COMPRESSION 'ZSTD',
        ROW_GROUP_SIZE 60000,
        KV_METADATA {
            'source': 'OpenStreetMap',
            'origin': 'OpenStreetMap (https://www.openstreetmap.org)',
            'dataset': 'OpenStreetMap POIs (Overture Places Schema Compatible)',
            'attribution': '© OpenStreetMap contributors',
            'attribution_url': 'https://www.openstreetmap.org/copyright',
            'license': 'ODbL-1.0 (https://opendatacommons.org/licenses/odbl/)',
            'license_url': 'https://opendatacommons.org/licenses/odbl/',
            'copyright': 'Data © OpenStreetMap contributors, licensed under Open Data Commons Open Database License 1.0 (ODbL)',
            'schema': 'Overture Maps theme=places / type=place',
            'schema_url': 'https://overturemaps.org/schema/',
            'schema_license': 'CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/)',
            'schema_license_url': 'https://creativecommons.org/licenses/by/4.0/',
            'schema_attribution': 'Schema specification © Overture Maps Foundation, licensed under Creative Commons Attribution 4.0 International (CC-BY-4.0)',
            'compiler': 'osm-pois (https://github.com/krizleebear/osm-pois)',
            'compiler_version': '$BUILD_VERSION',
            'country_code': '$COUNTRY_CODE',
            'exported_at': '$EXPORT_TIMESTAMP'
        }
    );
    "

    rm -rf "$SPLIT_DIR"
    trap - EXIT INT TERM

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    FILE_SIZE=$(du -sh "$OUTPUT_PARQUET" | cut -f1)
    POI_COUNT=$(duckdb -dark-mode -no-stdin -noheader -csv -c "SELECT count(*) FROM read_parquet('$OUTPUT_PARQUET');" 2>/dev/null | tail -n 1)
    echo "[OK] Successfully partitioned and merged GeoParquet: $OUTPUT_PARQUET ($FILE_SIZE, $POI_COUNT POIs) in ${ELAPSED}s"
    exit 0
fi

TMP_DIR=$(mktemp -d /tmp/duckdb_spill_XXXXXX)

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
    kill "$PYTHON_PID" 2>/dev/null || true
    rm -rf "$TMP_DIR"
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

        # If osm_pid equals duck_pid (Python driver parent), discover osmium child PID
        local actual_osm_pid="$osm_pid"
        if [ "$osm_pid" = "$duck_pid" ]; then
            actual_osm_pid=$(pgrep -P "$duck_pid" osmium 2>/dev/null || pgrep -P "$duck_pid" 2>/dev/null | head -n 1 || true)
        fi

        if [ -n "$actual_osm_pid" ] && kill -0 "$actual_osm_pid" 2>/dev/null; then
            local raw_osm
            raw_osm=$(get_rss_kb "$actual_osm_pid")
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

# Maximum size of a single GeoJSON sequence record accepted by the DuckDB JSON reader.
# Measured: the reader pre-allocates several buffers of this size, which dominates the
# fixed memory floor of the conversion (256 MB -> ~1120 MB, 64 MB -> ~490 MB).
# 64 MB stays safely above the largest record observed on large extracts
# (multipolygon relations of ~38 MB on the continental US) while removing ~600 MB
# of fixed overhead. Raise via OSM_POIS_MAX_OBJECT_SIZE (bytes) for extracts known
# to contain larger single features.
MAX_OBJECT_SIZE="${OSM_POIS_MAX_OBJECT_SIZE:-67108864}"

TMP_RELS_OPL="${TMP_DIR}/relations.opl"
echo "[STAGE 1/4] Pre-filtering relations into lightweight OPL index..."
osmium tags-filter -R "$INPUT_PBF" r/type=site,parking -f opl -o "$TMP_RELS_OPL" --overwrite 2>/dev/null || touch "$TMP_RELS_OPL"

echo "[STAGE 2/4] Streaming osmium export through chunked Python driver (chunk size: ${OSM_POIS_CHUNK_BYTES:-104857600} bytes)..."
python3 "$SCRIPT_DIR/entrypoint.py" \
  --input "$INPUT_PBF" \
  --output "$OUTPUT_PARQUET" \
  --relations-opl "$TMP_RELS_OPL" \
  --tmp-dir "$TMP_DIR" \
  --repo-root "$REPO_ROOT" \
  --country-code "$COUNTRY_CODE" \
  --spatial-filter "$SPATIAL_FILTER" \
  --max-object-size "$MAX_OBJECT_SIZE" \
  --chunk-bytes "${OSM_POIS_CHUNK_BYTES:-104857600}" \
  --build-version "$BUILD_VERSION" \
  --export-timestamp "$EXPORT_TIMESTAMP" &
PYTHON_PID=$!

monitor_resources "$PYTHON_PID" "$PYTHON_PID" &
MONITOR_PID=$!

set +e
wait "$PYTHON_PID"
PYTHON_EXIT=$?
set -e
stop_monitor

cleanup
trap - EXIT INT TERM

if [ $PYTHON_EXIT -ne 0 ]; then
    if [ $PYTHON_EXIT -eq 137 ]; then
        echo "****************************************************************"
        echo " [FATAL] Python driver was killed by SIGKILL (Exit code 137)!"
        echo " Cause: Out-Of-Memory (OOM) killer terminated the process."
        echo " Diagnostics: Memory limit exceeded the available container RAM."
        echo "****************************************************************"
    else
        echo "[FAIL] Python streaming driver failed with exit code $PYTHON_EXIT"
    fi
    exit $PYTHON_EXIT
fi

echo "[STAGE 3/4] Stream conversion completed successfully."
echo "[STAGE 4/4] Validating GeoParquet output..."

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
