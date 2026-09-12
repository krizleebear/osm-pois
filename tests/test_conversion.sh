#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Run fast unit tests & taxonomy linter first (< 100ms)
"$SCRIPT_DIR/run_unit_tests.sh"
echo ""

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
duckdb -dark-mode -no-stdin -c "
SELECT 
    count(*) AS total_pois,
    count(DISTINCT id) AS unique_ids,
    count(CASE WHEN categories.primary IS NOT NULL THEN 1 END) AS with_category,
    count(CASE WHEN bbox.xmin IS NOT NULL THEN 1 END) AS with_bbox,
    count(CASE WHEN addresses != [] THEN 1 END) AS with_address
FROM '$OUTPUT_PARQUET';
"

# Validation assertions
STATS=$(duckdb -dark-mode -no-stdin -noheader -csv -c "
SELECT 
    count(*),
    count(DISTINCT id),
    count(CASE WHEN categories.primary IS NOT NULL THEN 1 END),
    count(CASE WHEN id LIKE 'osm:way/%' THEN 1 END),
    count(CASE WHEN addresses != [] THEN 1 END)
FROM '$OUTPUT_PARQUET';
")

TOTAL_COUNT=$(echo "$STATS" | cut -d',' -f1)
UNIQUE_IDS=$(echo "$STATS" | cut -d',' -f2)
WITH_CAT=$(echo "$STATS" | cut -d',' -f3)
WAY_COUNT=$(echo "$STATS" | cut -d',' -f4)
WITH_ADDR=$(echo "$STATS" | cut -d',' -f5)

if [ "$TOTAL_COUNT" -lt 100 ]; then
    echo "[FAIL] Expected at least 100 POIs, got $TOTAL_COUNT"
    exit 1
fi
if [ "$UNIQUE_IDS" -ne "$TOTAL_COUNT" ]; then
    echo "[FAIL] Expected unique_ids ($UNIQUE_IDS) to equal total_count ($TOTAL_COUNT)"
    exit 1
fi
if [ "$WITH_CAT" -ne "$TOTAL_COUNT" ]; then
    echo "[FAIL] Expected all POIs to have categories, got $WITH_CAT / $TOTAL_COUNT"
    exit 1
fi
if [ "$WAY_COUNT" -lt 10 ]; then
    echo "[FAIL] Expected at least 10 way/polygon POIs (Osmium reconstruction), got $WAY_COUNT"
    exit 1
fi
if [ "$WITH_ADDR" -lt 10 ]; then
    echo "[FAIL] Expected at least 10 POIs with addresses, got $WITH_ADDR"
    exit 1
fi

echo "=== [OK] Integration Test Passed ($TOTAL_COUNT POIs generated, $WAY_COUNT ways reconstructed, $WITH_ADDR with addresses) ==="
rm -f "$OUTPUT_PARQUET"
