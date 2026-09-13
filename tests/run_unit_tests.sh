#!/bin/bash
# ============================================================================
# run_unit_tests.sh — Fast DuckDB Unit Tests for OSM-POIS Taxonomy & Mappings
# Usage: ./tests/run_unit_tests.sh
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Running OSM-POIS DuckDB Unit Tests & Linter ==="

START_TIME=$(date +%s%N 2>/dev/null || date +%s)

# Execute unit tests via DuckDB in non-interactive mode
duckdb -dark-mode -no-stdin -c ".read $SCRIPT_DIR/test_unit.sql"

END_TIME=$(date +%s%N 2>/dev/null || date +%s)

# calculate elapsed time in ms if nanoseconds supported
if [ ${#START_TIME} -gt 10 ]; then
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    echo "=== [OK] Unit Tests Completed in ${ELAPSED_MS}ms ==="
else
    ELAPSED=$(( END_TIME - START_TIME ))
    echo "=== [OK] Unit Tests Completed in ${ELAPSED}s ==="
fi

# Verify Azure Pipelines matrix priority ordering (DE -> AT -> CH)
if [ -f "$REPO_ROOT/azure-pipelines.yml" ]; then
    FIRST_THREE=$(sed -n '/strategy:/,/steps:/p' "$REPO_ROOT/azure-pipelines.yml" | grep -E '^[[:space:]]{8}[a-z0-9_-]+:' | head -n 3 | awk '{print $1}' | tr -d ':' | tr '\n' ' ')
    if [ "$FIRST_THREE" != "01_germany 02_austria 03_switzerland " ]; then
        echo "ERROR: azure-pipelines.yml matrix must start with 01_germany, 02_austria, 03_switzerland (got: $FIRST_THREE)"
        exit 1
    fi
    echo "=== [OK] Pipeline Matrix DACH Priority Verified (01_germany, 02_austria, 03_switzerland) ==="
fi
