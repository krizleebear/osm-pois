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
    count(CASE WHEN addresses != [] THEN 1 END),
    count(CASE WHEN version > 0 THEN 1 END),
    count(CASE WHEN version > 1 THEN 1 END),
    count(CASE WHEN sources[1].dataset = 'OpenStreetMap' AND sources[1].license = 'ODbL-1.0' AND sources[1].update_time IS NOT NULL THEN 1 END)
FROM '$OUTPUT_PARQUET';
")

TOTAL_COUNT=$(echo "$STATS" | cut -d',' -f1)
UNIQUE_IDS=$(echo "$STATS" | cut -d',' -f2)
WITH_CAT=$(echo "$STATS" | cut -d',' -f3)
WAY_COUNT=$(echo "$STATS" | cut -d',' -f4)
WITH_ADDR=$(echo "$STATS" | cut -d',' -f5)
WITH_VER=$(echo "$STATS" | cut -d',' -f6)
MULTI_VER=$(echo "$STATS" | cut -d',' -f7)
VALID_SOURCES=$(echo "$STATS" | cut -d',' -f8)

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
if [ "$WITH_VER" -ne "$TOTAL_COUNT" ]; then
    echo "[FAIL] Expected all POIs to have version > 0, got $WITH_VER / $TOTAL_COUNT"
    exit 1
fi
if [ "$MULTI_VER" -lt 10 ]; then
    echo "[FAIL] Expected multiple POIs with version > 1, got $MULTI_VER"
    exit 1
fi
if [ "$VALID_SOURCES" -ne "$TOTAL_COUNT" ]; then
    echo "[FAIL] Expected all POIs to have valid OSM source and timestamp, got $VALID_SOURCES / $TOTAL_COUNT"
    exit 1
fi

# Verify Schema Types, Multilingual Names & Micro-infrastructure filtering
SCHEMA_CHECK=$(duckdb -dark-mode -no-stdin -noheader -csv -c "
SELECT 
    count(CASE WHEN typeof(names.rules) LIKE 'STRUCT%[]' THEN 1 END),
    count(CASE WHEN typeof(brand.names.rules) LIKE 'STRUCT%[]' THEN 1 END),
    count(CASE WHEN typeof(names.common) = 'MAP(VARCHAR, VARCHAR)' THEN 1 END),
    count(CASE WHEN typeof(brand.names.common) = 'MAP(VARCHAR, VARCHAR)' THEN 1 END),
    count(CASE WHEN cardinality(names.common) > 0 THEN 1 END),
    count(CASE WHEN categories.primary IN ('bench', 'waste_basket', 'shelter', 'grit_bin', 'hunting_stand', 'feeding_place', 'waste_disposal', 'ticket_validator', 'board', 'guidepost') THEN 1 END),
    count(CASE WHEN categories.primary = 'post_box' THEN 1 END),
    count(CASE WHEN categories.primary = 'visitor_center' THEN 1 END)
FROM '$OUTPUT_PARQUET';
")

VALID_NAMES_RULES=$(echo "$SCHEMA_CHECK" | cut -d',' -f1)
VALID_BRAND_RULES=$(echo "$SCHEMA_CHECK" | cut -d',' -f2)
VALID_NAMES_COMMON=$(echo "$SCHEMA_CHECK" | cut -d',' -f3)
VALID_BRAND_COMMON=$(echo "$SCHEMA_CHECK" | cut -d',' -f4)
COMMON_NAMES_COUNT=$(echo "$SCHEMA_CHECK" | cut -d',' -f5)
MICRO_COUNT=$(echo "$SCHEMA_CHECK" | cut -d',' -f6)
POST_BOX_COUNT=$(echo "$SCHEMA_CHECK" | cut -d',' -f7)
VISITOR_CENTER_COUNT=$(echo "$SCHEMA_CHECK" | cut -d',' -f8)

if [ "$VALID_NAMES_RULES" -ne "$TOTAL_COUNT" ] || [ "$VALID_BRAND_RULES" -ne "$TOTAL_COUNT" ]; then
    echo "[FAIL] Expected rules columns to be typed as STRUCT[], got names.rules=$VALID_NAMES_RULES, brand.names.rules=$VALID_BRAND_RULES"
    exit 1
fi
if [ "$VALID_NAMES_COMMON" -ne "$TOTAL_COUNT" ] || [ "$VALID_BRAND_COMMON" -ne "$TOTAL_COUNT" ]; then
    echo "[FAIL] Expected common columns to be typed as MAP(VARCHAR, VARCHAR), got names.common=$VALID_NAMES_COMMON, brand.names.common=$VALID_BRAND_COMMON"
    exit 1
fi
if [ "$COMMON_NAMES_COUNT" -lt 50 ]; then
    echo "[FAIL] Expected at least 50 POIs with multilingual names.common, got $COMMON_NAMES_COUNT"
    exit 1
fi
if [ "$MICRO_COUNT" -ne 0 ]; then
    echo "[FAIL] Expected 0 micro-infrastructure POIs (benches/waste baskets/shelters/info boards), got $MICRO_COUNT"
    exit 1
fi
if [ "$POST_BOX_COUNT" -lt 1 ]; then
    echo "[FAIL] Expected post boxes to be retained, got $POST_BOX_COUNT"
    exit 1
fi
if [ "$VISITOR_CENTER_COUNT" -gt 10 ] || [ "$VISITOR_CENTER_COUNT" -lt 1 ]; then
    echo "[FAIL] Expected between 1 and 10 real visitor centers in Monaco, got $VISITOR_CENTER_COUNT"
    exit 1
fi

# Verify Parquet File-Level KV_METADATA
META_STATS=$(duckdb -dark-mode -no-stdin -noheader -csv -c "
SELECT 
    count(CASE WHEN key = 'attribution' AND CAST(value AS VARCHAR) LIKE '%OpenStreetMap%' THEN 1 END),
    count(CASE WHEN key = 'license' AND CAST(value AS VARCHAR) LIKE '%ODbL%' THEN 1 END),
    count(CASE WHEN key = 'source' AND CAST(value AS VARCHAR) = 'OpenStreetMap' THEN 1 END),
    count(CASE WHEN key = 'compiler' AND CAST(value AS VARCHAR) LIKE '%osm-pois%' THEN 1 END),
    count(CASE WHEN key = 'country_code' AND CAST(value AS VARCHAR) = 'MC' THEN 1 END),
    count(CASE WHEN key = 'schema_license' AND CAST(value AS VARCHAR) LIKE '%CC-BY-4.0%' THEN 1 END),
    count(CASE WHEN key = 'schema_attribution' AND CAST(value AS VARCHAR) LIKE '%Overture Maps Foundation%' THEN 1 END)
FROM parquet_kv_metadata('$OUTPUT_PARQUET');
")

HAS_ATTR=$(echo "$META_STATS" | cut -d',' -f1)
HAS_LIC=$(echo "$META_STATS" | cut -d',' -f2)
HAS_SRC=$(echo "$META_STATS" | cut -d',' -f3)
HAS_COMP=$(echo "$META_STATS" | cut -d',' -f4)
HAS_CC=$(echo "$META_STATS" | cut -d',' -f5)
HAS_SCHEMA_LIC=$(echo "$META_STATS" | cut -d',' -f6)
HAS_SCHEMA_ATTR=$(echo "$META_STATS" | cut -d',' -f7)

if [ "$HAS_ATTR" -ne 1 ] || [ "$HAS_LIC" -ne 1 ] || [ "$HAS_SRC" -ne 1 ] || [ "$HAS_COMP" -ne 1 ] || [ "$HAS_CC" -ne 1 ] || [ "$HAS_SCHEMA_LIC" -ne 1 ] || [ "$HAS_SCHEMA_ATTR" -ne 1 ]; then
    echo "[FAIL] Parquet KV_METADATA validation failed: attribution=$HAS_ATTR, license=$HAS_LIC, source=$HAS_SRC, compiler=$HAS_COMP, country_code=$HAS_CC, schema_license=$HAS_SCHEMA_LIC, schema_attribution=$HAS_SCHEMA_ATTR"
    exit 1
fi

echo "=== [OK] Integration Test Passed ($TOTAL_COUNT POIs generated, $WAY_COUNT ways, $WITH_ADDR with addresses, $COMMON_NAMES_COUNT multilingual names, $POST_BOX_COUNT post boxes, rules STRUCT[] & common MAP schema types verified, Parquet KV metadata verified) ==="
rm -f "$OUTPUT_PARQUET"
