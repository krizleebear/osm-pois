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

TMP_SQL=$(mktemp /tmp/export_XXXXXX.sql)
sed \
  -e "s|__INPUT_PBF__|${INPUT_PBF}|g" \
  -e "s|__OUTPUT_PARQUET__|${OUTPUT_PARQUET}|g" \
  -e "s|__COUNTRY_CODE__|${COUNTRY_CODE}|g" \
  -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  "$SCRIPT_DIR/export_pois.sql" > "$TMP_SQL"

duckdb < "$TMP_SQL"
rm -f "$TMP_SQL"

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
