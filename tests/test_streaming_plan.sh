#!/bin/bash
# ============================================================================
# test_streaming_plan.sh — Streaming Physical Plan Regression Test (<1s, no PBF)
#
# Guards the core streaming invariant of scripts/export_pois.sql:
#   The read_json() FIFO stream must NEVER end up on the build side of a hash join.
#
# Background: a named pipe has no file size, so DuckDB estimates the read_json()
# stream at only a few dozen rows. Large extracts (DE, US, FR, ...) produce relation
# membership indexes with 100k+ rows. Without pinning, DuckDB's build_side_probe_side
# optimizer swaps the LEFT JOIN against osm_relation_members and builds the hash table
# over the entire POI stream, materializing every POI in RAM before the first Parquet
# row group is written ("failed to allocate ... (4.4 GiB/4.4 GiB used)").
#
# This test plans the PRODUCTION query against a real FIFO and a synthetic relation
# index of 200,000 members, and asserts via the JSON physical plan that READ_JSON only
# ever appears on probe sides (child 0) of HASH_JOIN operators.
# Usage: ./tests/test_streaming_plan.sh
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR=$(mktemp -d /tmp/osm_pois_plan_test_XXXXXX)
FIFO="$WORK_DIR/stream.jsonl"
RELS_OPL="$WORK_DIR/relations.opl"
PLAN_JSON="$WORK_DIR/plan.json"

cleanup() {
    exec 3>&- 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkfifo "$FIFO"
# Hold the FIFO open read-write so that no opener can ever block on it.
exec 3<>"$FIFO"

# Synthetic relation index: 2,000 site relations x 100 node members = 200,000 members,
# i.e. the same order of magnitude as the DE extract (~154k members).
duckdb -dark-mode -no-stdin -c "
COPY (
    SELECT 'r' || r || ' v1 dV c1 t2026-01-01T00:00:00Z i1 utest Ttype=site,site=parking M'
           || string_agg('n' || (r * 100 + m) || '@', ',' ORDER BY m) AS line
    FROM range(1, 2001) a(r), range(100) b(m)
    GROUP BY r
) TO '$RELS_OPL' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');
"

sed \
  -e "s|__INPUT_JSONL__|${FIFO}|g" \
  -e "s|__INPUT_RELATIONS_OPL__|${RELS_OPL}|g" \
  -e "s|__OUTPUT_PARQUET__|${WORK_DIR}/out.parquet|g" \
  -e "s|__COUNTRY_CODE__|XX|g" \
  -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  -e "s|__BUILD_VERSION__|test|g" \
  -e "s|__EXPORT_TIMESTAMP__|1970-01-01T00:00:00Z|g" \
  -e "s|__TEMP_DIR__|${WORK_DIR}|g" \
  -e "s|__SPATIAL_FILTER__||g" \
  -e "s|__MAX_OBJECT_SIZE__|67108864|g" \
  -e "s|^COPY (|EXPLAIN (FORMAT JSON) COPY (|" \
  "$REPO_ROOT/scripts/export_pois.sql" > "$WORK_DIR/plan_query.sql"

if ! grep -q '^EXPLAIN (FORMAT JSON) COPY (' "$WORK_DIR/plan_query.sql"; then
    echo "ERROR: Could not locate the top-level 'COPY (' statement in scripts/export_pois.sql."
    echo "       The streaming plan test rewrites it into EXPLAIN; keep 'COPY (' at line start."
    exit 1
fi

duckdb -dark-mode -no-stdin -noheader -list -c ".read $WORK_DIR/plan_query.sql" \
    | sed -n '/^\[/,$p' > "$PLAN_JSON"

if [ ! -s "$PLAN_JSON" ]; then
    echo "ERROR: Failed to capture the JSON physical plan of scripts/export_pois.sql."
    exit 1
fi

# Walk the plan tree; a node is on a build side if it (or an ancestor) is child >= 1 of a HASH_JOIN.
RESULT=$(duckdb -dark-mode -no-stdin -noheader -csv -c "
WITH RECURSIVE nodes(node, on_build_side) AS (
    SELECT json_extract(j, '\$[0]'), false
    FROM read_text('$PLAN_JSON') t(filename, content, size, last_modified), LATERAL (SELECT content::JSON AS j)
    UNION ALL
    SELECT
        json_extract(n.node, '\$.children[' || i || ']'),
        n.on_build_side OR (json_extract_string(n.node, '\$.name') = 'HASH_JOIN' AND i >= 1)
    FROM nodes n, range(CAST(json_array_length(json_extract(n.node, '\$.children')) AS BIGINT)) r(i)
)
SELECT
    count(*) FILTER (WHERE json_extract_string(node, '\$.name') = 'READ_JSON'),
    count(*) FILTER (WHERE json_extract_string(node, '\$.name') = 'READ_JSON' AND on_build_side),
    count(*) FILTER (WHERE json_extract_string(node, '\$.name') = 'HASH_JOIN')
FROM nodes;
" | tail -n 1)

if ! [[ "$RESULT" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]]; then
    echo "ERROR: Failed to analyze the JSON physical plan (got: '$RESULT')."
    exit 1
fi

READ_JSON_NODES=$(echo "$RESULT" | cut -d',' -f1)
READ_JSON_ON_BUILD=$(echo "$RESULT" | cut -d',' -f2)
HASH_JOINS=$(echo "$RESULT" | cut -d',' -f3)

if [ "$READ_JSON_NODES" -lt 1 ] || [ "$HASH_JOINS" -lt 1 ]; then
    echo "ERROR: Unexpected plan shape (READ_JSON nodes=$READ_JSON_NODES, HASH_JOIN nodes=$HASH_JOINS)."
    echo "       The streaming plan test could not find the read_json() stream or the relation join."
    exit 1
fi

if [ "$READ_JSON_ON_BUILD" -ne 0 ]; then
    echo "****************************************************************"
    echo " [FAIL] Streaming invariant violated: the read_json() FIFO stream is on the"
    echo "        BUILD side of a HASH_JOIN ($READ_JSON_ON_BUILD occurrence(s))."
    echo ""
    echo " Cause:  DuckDB materializes the entire POI stream into a hash table,"
    echo "         which causes OOM on large extracts (DE, US, FR, ...)."
    echo " Fix:    Keep 'SET disabled_optimizers = ''build_side_probe_side'';' before the"
    echo "         COPY in scripts/export_pois.sql, and keep the stream as the LEFT input"
    echo "         of every join (small lookup tables on the right/build side)."
    echo "****************************************************************"
    exit 1
fi

echo "=== [OK] Streaming Plan Verified: read_json() stream is probe-side only ($HASH_JOINS hash joins, 200k-member relation index) ==="
