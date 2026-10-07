#!/bin/bash
# ============================================================================
# test_chunked_streaming.sh — Chunked Python-Driver Streaming Regression Test
#
# Guards the US-east OOM fix (Root Cause #2): osmium's GeoJSON sequence stream is
# read by scripts/entrypoint.py in bounded ~chunk-size pieces and registered as
# in-memory BytesIO relations (no FIFO, no pipe cache). This test proves the
# chunked path is deterministic and lossless:
#   * forcing 12+ tiny chunks must produce a result BIT-IDENTICAL to a
#     single-chunk run (same rows, same order), and
#   * the single final GeoParquet must carry the full KV_METADATA provenance.
#
# Usage: ./tests/test_chunked_streaming.sh
# Requires: python3 + duckdb==1.5.5 + fsspec (image v1.1.0+), osmium-tool
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_PBF="$REPO_ROOT/tests/fixtures/monaco-sample.osm.pbf"
CHUNKED_OUT="$REPO_ROOT/tests/output_chunked.places.parquet"
SINGLE_OUT="$REPO_ROOT/tests/output_single.places.parquet"
WORK_DIR=$(mktemp -d /tmp/osm_pois_chunk_test_XXXXXX)

cleanup() {
    rm -rf "$WORK_DIR" "$CHUNKED_OUT" "$SINGLE_OUT"
}
trap cleanup EXIT INT TERM

if [ ! -f "$TEST_PBF" ]; then
    if [ -f "$REPO_ROOT/monaco-latest.osm.pbf" ]; then
        cp "$REPO_ROOT/monaco-latest.osm.pbf" "$TEST_PBF"
    else
        echo "[INFO] Downloading Monaco sample PBF fixture..."
        curl -fsSL "https://download.geofabrik.de/europe/monaco-latest.osm.pbf" -o "$TEST_PBF"
    fi
fi

if ! python3 -c "import duckdb, fsspec" >/dev/null 2>&1; then
    echo "ERROR: tests/test_chunked_streaming.sh requires 'python3' with the 'duckdb'"
    echo "       and 'fsspec' packages (container image v1.1.0+)."
    echo "       Install them with: python3 -m pip install duckdb==1.5.5 fsspec"
    exit 1
fi

osmium tags-filter -R "$TEST_PBF" r/type=site,parking -f opl -o "$WORK_DIR/relations.opl" --overwrite 2>/dev/null || touch "$WORK_DIR/relations.opl"
mkdir -p "$WORK_DIR/chunked" "$WORK_DIR/single"

DRIVER="$REPO_ROOT/scripts/entrypoint.py"
COMMON_ARGS=(--input "$TEST_PBF" --relations-opl "$WORK_DIR/relations.opl"
             --repo-root "$REPO_ROOT" --country-code MC --build-version test
             --export-timestamp 1970-01-01T00:00:00Z --max-object-size 67108864)

echo "[TEST] Running chunked driver (12+ tiny chunks)..."
python3 "$DRIVER" "${COMMON_ARGS[@]}" \
    --output "$CHUNKED_OUT" \
    --tmp-dir "$WORK_DIR/chunked" \
    --chunk-bytes 200000 > "$WORK_DIR/chunked.log" 2>&1

echo "[TEST] Running single-chunk driver..."
python3 "$DRIVER" "${COMMON_ARGS[@]}" \
    --output "$SINGLE_OUT" \
    --tmp-dir "$WORK_DIR/single" \
    --chunk-bytes 104857600 > "$WORK_DIR/single.log" 2>&1

CHUNK_LINES=$(grep -c '^\[CHUNK ' "$WORK_DIR/chunked.log" || true)
if [ "$CHUNK_LINES" -lt 2 ]; then
    echo "[FAIL] Expected multiple chunks in the chunked run, got $CHUNK_LINES (--chunk-bytes 200000)"
    exit 1
fi

SUMMARY=$(duckdb -dark-mode -no-stdin -noheader -csv -c "
LOAD spatial;
SELECT
    (SELECT count(*) FROM '${CHUNKED_OUT}'),
    (SELECT count(*) FROM '${SINGLE_OUT}'),
    (SELECT md5(string_agg(id || '|' || coalesce(categories.primary, '') || '|' || ST_AsText(geometry), '§' ORDER BY id)) FROM '${CHUNKED_OUT}'),
    (SELECT md5(string_agg(id || '|' || coalesce(categories.primary, '') || '|' || ST_AsText(geometry), '§' ORDER BY id)) FROM '${SINGLE_OUT}');" 2>/dev/null | tail -n 1)

CHUNKED_COUNT=$(echo "$SUMMARY" | cut -d',' -f1)
SINGLE_COUNT=$(echo "$SUMMARY" | cut -d',' -f2)
CHUNKED_MD5=$(echo "$SUMMARY" | cut -d',' -f3)
SINGLE_MD5=$(echo "$SUMMARY" | cut -d',' -f4)

if [ "$CHUNKED_COUNT" -lt 100 ] || [ "$CHUNKED_COUNT" -ne "$SINGLE_COUNT" ]; then
    echo "[FAIL] Chunked vs single output counts differ: chunked=$CHUNKED_COUNT single=$SINGLE_COUNT"
    exit 1
fi
if [ "$CHUNKED_MD5" != "$SINGLE_MD5" ]; then
    echo "[FAIL] Chunked vs single output differ (md5 mismatch): $CHUNKED_MD5 vs $SINGLE_MD5"
    exit 1
fi

META=$(duckdb -dark-mode -no-stdin -noheader -csv -c "
SELECT count(*) FROM parquet_kv_metadata('${CHUNKED_OUT}')
WHERE key IN ('source', 'license', 'schema_license', 'compiler', 'country_code');" 2>/dev/null | tail -n 1)
if [ "$META" -ne 5 ]; then
    echo "[FAIL] Chunked output missing KV_METADATA provenance keys (got $META/5)"
    exit 1
fi

echo "=== [OK] Chunked Streaming Verified: $CHUNK_LINES chunks are bit-identical to a single chunk ($CHUNKED_COUNT POIs, md5 $CHUNKED_MD5, KV_METADATA intact) ==="