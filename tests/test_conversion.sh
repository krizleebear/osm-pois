#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Running OSM-POIS Local Integration Test ==="

TEST_PBF="$REPO_ROOT/tests/fixtures/monaco-sample.osm.pbf"
OUTPUT_PARQUET="$REPO_ROOT/tests/output_sample.places.parquet"

# Ensure fixture exists
if [ ! -f "$TEST_PBF" ]; then
    if [ -f "$REPO_ROOT/monaco-latest.osm.pbf" ]; then
        cp "$REPO_ROOT/monaco-latest.osm.pbf" "$TEST_PBF"
    else
        echo "[INFO] Downloading Monaco sample PBF fixture..."
        curl -fsSL "https://download.geofabrik.de/europe/monaco-latest.osm.pbf" -o "$TEST_PBF"
    fi
fi

rm -f "$OUTPUT_PARQUET"

echo "[TEST] Running entrypoint.sh on test fixture..."
"$REPO_ROOT/scripts/entrypoint.sh" "$TEST_PBF" "$OUTPUT_PARQUET" "MC"

echo "[TEST] Verifying generated GeoParquet via DuckDB..."
duckdb -c "
SELECT 
    count(*) AS total_pois,
    count(DISTINCT id) AS unique_ids,
    count(CASE WHEN categories.primary IS NOT NULL THEN 1 END) AS with_category,
    count(CASE WHEN bbox.xmin IS NOT NULL THEN 1 END) AS with_bbox,
    count(CASE WHEN addresses != [] THEN 1 END) AS with_address
FROM '$OUTPUT_PARQUET';
"

# Basic validation assertions
TOTAL_COUNT=$(duckdb -noheader -csv -c "SELECT count(*) FROM '$OUTPUT_PARQUET';")
if [ "$TOTAL_COUNT" -lt 100 ]; then
    echo "[FAIL] Expected at least 100 POIs, got $TOTAL_COUNT"
    exit 1
fi

echo "=== [OK] Integration Test Passed ($TOTAL_COUNT POIs generated) ==="
rm -f "$OUTPUT_PARQUET"
