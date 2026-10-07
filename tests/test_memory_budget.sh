#!/bin/bash
# ============================================================================
# test_memory_budget.sh — Peak-RSS Budget Regression for Single-Pass Parsing
#
# Guards the Taiwan OOM fix: GeoJSON `properties` must be read as a parsed
# MAP(VARCHAR, VARCHAR) and every tag access must be a map lookup (never
# json_extract_*/json_keys, which re-parse the full document per access and make
# per-row cost quadratic in tag count).
#
# The test builds a synthetic tag-rich extract (multilingual names, payment:*
# namespaces, lifecycle prefixes - i.e. the key patterns that trigger the
# key-iterating macros), streams it through the production Python driver in one
# 100 MB chunk and asserts the driver's peak RSS stays inside the budget.
#
# Discriminating power: with the legacy JSON reader the same chunk peaks well
# above 3 GB (measured 5.7 GB on a comparable 100 MB chunk, OOM at the
# 4.4 GiB max_memory cap), while the MAP rewrite runs at ~0.45 GB.
#
# Usage: ./tests/test_memory_budget.sh
# Requires: python3 + duckdb==1.5.5 + fsspec (image v1.1.0+), osmium-tool
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Peak RSS budget for the streaming driver (KB). 1.5 GB leaves ~3x headroom over
# the measured MAP result and still fails loudly on the legacy JSON reader.
PEAK_BUDGET_KB=$((1536 * 1024))

# Synthetic extract size: one 100 MB ingest chunk of tag-rich points.
NODE_COUNT="${OSM_POIS_TEST_NODES:-60000}"

WORK_DIR=$(mktemp -d /tmp/osm_pois_mem_budget_XXXXXX)
OUT_PARQUET="$WORK_DIR/out.places.parquet"
XML_FILE="$WORK_DIR/tag_rich.osm.xml"
PBF_FILE="$WORK_DIR/tag_rich.osm.pbf"
RELS_OPL="$WORK_DIR/relations.opl"
PEAK_FILE="$WORK_DIR/peak_rss_kb.txt"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

if ! python3 -c "import duckdb, fsspec" >/dev/null 2>&1; then
    echo "ERROR: tests/test_memory_budget.sh requires 'python3' with the 'duckdb'"
    echo "       and 'fsspec' packages (container image v1.1.0+)."
    echo "       Install them with: python3 -m pip install duckdb==1.5.5 fsspec"
    exit 1
fi

echo "[TEST] Generating synthetic tag-rich extract ($NODE_COUNT nodes)..."
python3 - "$XML_FILE" "$NODE_COUNT" <<'PYGEN'
import sys

out_path, count = sys.argv[1], int(sys.argv[2])
shops = ["supermarket", "convenience", "cafe", "restaurant", "clothes", "pharmacy",
         "bakery", "hairdresser", "books", "hardware", "florist", "electronics"]
amenities = ["parking", "post_box", "toilets", "atm", "fuel", "library", "school",
             "place_of_worship", "pharmacy", "bench", "waste_basket"]
zh_names = ["台北車站", "永康街商圈", "鹿港老街", "阿里山國家風景區", "墾丁國家公園"]
en_names = ["Taipei Main Station", "Yongkang Street", "Lukang Old Street",
            "Alishan National Scenic Area", "Kenting National Park"]

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    fh.write('<osm version="0.6" generator="osm-pois-memory-budget-test">\n')
    for i in range(count):
        fh.write('<node id="%d" lat="23.%07d" lon="120.%07d" version="%d" '
                 'timestamp="2024-01-01T00:00:00Z">\n'
                 % (i + 1, i % 10000000, i % 10000000, (i % 12) + 1))
        tags = {
            "name": zh_names[i % len(zh_names)] + " " + str(i),
            "name:en": en_names[i % len(en_names)],
            "name:zh-Hant": zh_names[i % len(zh_names)],
            "name:zh-Hans": zh_names[i % len(zh_names)].replace("區", "区"),
            "name:ja": en_names[i % len(en_names)],
            "name:ko": en_names[i % len(en_names)],
            "alt_name": en_names[i % len(en_names)],
            "int_name": en_names[i % len(en_names)],
            "name:etymology:wikidata": "Q123",
            "addr:street": "忠孝東路%d段" % (i % 9 + 1),
            "addr:housenumber": str(i % 500 + 1),
            "addr:city": "台北市",
            "addr:postcode": "106%d" % (i % 10),
            "phone": "+886-2-1234-5678",
            "website": "https://example.tw/",
            "opening_hours": "Mo-Su 08:00-22:00",
            "wheelchair": "yes",
            "cuisine": "taiwanese",
            "payment:cash": "yes",
            "payment:credit_cards": "yes",
            "payment:electronic_money": "yes",
            "operator": "台北市政府",
            "wikidata": "Q789",
            "brand": en_names[i % len(en_names)],
            "description": "測試描述 description de prueba",
        }
        if i % 3 == 0:
            tags["shop"] = shops[i % len(shops)]
        else:
            tags["amenity"] = amenities[i % len(amenities)]
        if i % 7 == 0:
            tags["building"] = "yes"
        if i % 11 == 0:
            tags["disused:amenity"] = "theatre"
        for key, value in tags.items():
            fh.write('  <tag k="%s" v="%s"/>\n'
                     % (key, value.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;")))
        fh.write("</node>\n")
    fh.write("</osm>\n")
PYGEN

echo "[TEST] Converting to PBF and building the relation index..."
osmium cat "$XML_FILE" -o "$PBF_FILE" --overwrite
osmium tags-filter -R "$PBF_FILE" r/type=site,parking -f opl -o "$RELS_OPL" --overwrite \
    2>/dev/null || touch "$RELS_OPL"
rm -f "$XML_FILE"

DRIVER="$REPO_ROOT/scripts/entrypoint.py"
echo "[TEST] Streaming through the production driver (single 100 MB chunk)..."
PEAK_FILE="$PEAK_FILE" python3 - "$DRIVER" \
    --input "$PBF_FILE" \
    --output "$OUT_PARQUET" \
    --relations-opl "$RELS_OPL" \
    --repo-root "$REPO_ROOT" \
    --country-code XX \
    --build-version test \
    --export-timestamp 1970-01-01T00:00:00Z \
    --max-object-size 67108864 \
    --chunk-bytes 104857600 \
    --tmp-dir "$WORK_DIR" <<'PYRUN'
import os
import resource
import subprocess
import sys

rc = subprocess.call([sys.executable] + sys.argv[1:])
peak_kb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
with open(os.environ["PEAK_FILE"], "w", encoding="ascii") as fh:
    fh.write(str(peak_kb))
sys.exit(rc)
PYRUN

PEAK_KB=$(cat "$PEAK_FILE")
ROW_COUNT=$(duckdb -dark-mode -no-stdin -noheader -csv -c \
    "SELECT count(*) FROM read_parquet('$OUT_PARQUET');" 2>/dev/null | tail -n 1)

# ~80% of the synthetic nodes qualify (the remainder are deliberately tagged with
# micro-infrastructure amenities such as bench/waste_basket, which the POI filter
# must reject even when they carry a name).
MIN_EXPECTED_ROWS=$((NODE_COUNT * 8 / 10))
if [ -z "$ROW_COUNT" ] || [ "$ROW_COUNT" -lt "$MIN_EXPECTED_ROWS" ]; then
    echo "[FAIL] Expected at least $MIN_EXPECTED_ROWS POIs in the synthetic extract, got '$ROW_COUNT'"
    exit 1
fi

PEAK_MB=$((PEAK_KB / 1024))
BUDGET_MB=$((PEAK_BUDGET_KB / 1024))
if [ "$PEAK_KB" -gt "$PEAK_BUDGET_KB" ]; then
    echo "****************************************************************"
    echo " [FAIL] Peak RSS budget exceeded: ${PEAK_MB} MB > ${BUDGET_MB} MB"
    echo ""
    echo " Cause:  GeoJSON properties are no longer parsed exactly once."
    echo "         Check scripts/export_pois.sql and scripts/entrypoint.py for a"
    echo "         'properties': 'JSON' reader column and scripts/sql/*.sql for"
    echo "         json_extract_* / json_keys calls on props/properties."
    echo " Fix:    Read properties as MAP(VARCHAR, VARCHAR) and use map lookups."
    echo "****************************************************************"
    exit 1
fi

echo "=== [OK] Memory budget verified: peak RSS ${PEAK_MB} MB <= ${BUDGET_MB} MB for a tag-rich single chunk (${ROW_COUNT} POIs) ==="
