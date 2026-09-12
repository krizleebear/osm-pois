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
mkfifo "$TMP_FIFO"

cleanup() {
    kill "$OSMIUM_PID" 2>/dev/null || true
    rm -f "$TMP_FIFO" "$TMP_SQL"
}
trap cleanup EXIT INT TERM

# Stream Osmium export through named pipe directly into DuckDB (zero intermediate disk I/O)
(osmium export "$INPUT_PBF" --geometry-types=point,polygon -a type,id -f geojsonseq | tr -d '\036' > "$TMP_FIFO") &
OSMIUM_PID=$!

sed \
  -e "s|__INPUT_JSONL__|${TMP_FIFO}|g" \
  -e "s|__OUTPUT_PARQUET__|${OUTPUT_PARQUET}|g" \
  -e "s|__COUNTRY_CODE__|${COUNTRY_CODE}|g" \
  -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  "$SCRIPT_DIR/export_pois.sql" > "$TMP_SQL"

duckdb -dark-mode -no-stdin -c ".read $TMP_SQL"
DUCKDB_EXIT=$?

wait "$OSMIUM_PID" 2>/dev/null || true
cleanup
trap - EXIT INT TERM

if [ $DUCKDB_EXIT -ne 0 ]; then
    echo "[FAIL] DuckDB export failed with exit code $DUCKDB_EXIT"
    exit $DUCKDB_EXIT
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [ ! -f "$OUTPUT_PARQUET" ]; then
    echo "****************************************************************"
    echo " ERROR: Expected output file was not produced: $OUTPUT_PARQUET"
    echo "****************************************************************"
    exit 1
fi

FILE_SIZE=$(du -sh "$OUTPUT_PARQUET" | cut -f1)
echo "[OK] Successfully exported GeoParquet: $OUTPUT_PARQUET ($FILE_SIZE) in ${ELAPSED}s"
