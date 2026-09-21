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

# Verify Azure Pipelines Touchstone DE architecture
if [ -f "$REPO_ROOT/azure-pipelines.yml" ]; then
    if ! grep -q 'job: touchstone_germany' "$REPO_ROOT/azure-pipelines.yml"; then
        echo "ERROR: azure-pipelines.yml must define job: touchstone_germany!"
        exit 1
    fi
    if ! grep -q 'dependsOn: touchstone_germany' "$REPO_ROOT/azure-pipelines.yml"; then
        echo "ERROR: azure-pipelines.yml convert job must have dependsOn: touchstone_germany!"
        exit 1
    fi
    if [ ! -f "$REPO_ROOT/templates/convert-steps.yml" ]; then
        echo "ERROR: templates/convert-steps.yml is missing!"
        exit 1
    fi
    FIRST_TWO=$(sed -n '/strategy:/,/steps:/p' "$REPO_ROOT/azure-pipelines.yml" | grep -E '^[[:space:]]{8}[a-z0-9_-]+:' | head -n 2 | awk '{print $1}' | tr -d ':' | tr '\n' ' ')
    if [ "$FIRST_TWO" != "austria switzerland " ]; then
        echo "ERROR: azure-pipelines.yml matrix must start with austria, switzerland (got: $FIRST_TWO)"
        exit 1
    fi
    # Ensure preflight container run mounts to /workspace, not /app (which masks container's $HOME/.duckdb extension cache)
    if grep -E 'docker run.*-v.*: */app([[:space:]]|$)' "$REPO_ROOT/azure-pipelines.yml" >/dev/null; then
        echo "ERROR: azure-pipelines.yml preflight must mount repository to /workspace, not /app (masks container's pre-installed .duckdb extensions)!"
        exit 1
    fi
    echo "=== [OK] Touchstone DE Pipeline Architecture Verified (Germany first, Matrix follows) ==="
fi

# Verify Web Viewer Contract Integrity
if [ -f "$REPO_ROOT/viewer/index.html" ]; then
    REQUIRED_VIEWER_TOKENS=(
        "fileVersionBadge"
        "datasetMetaCard"
        "confidenceFilterSelect"
        "operationalFilterSelect"
        "opening_hours"
        "wheelchair"
        "payment_methods"
        "cuisine"
        "compiler_version"
        "availableColumns"
        "findNearestBtn"
        "jumpToNearestMatch"
    )
    for token in "${REQUIRED_VIEWER_TOKENS[@]}"; do
        if ! grep -q "$token" "$REPO_ROOT/viewer/index.html"; then
            echo "ERROR: viewer/index.html is missing required contract token: $token"
            exit 1
        fi
    done
    echo "=== [OK] Web Viewer Contract & Data Model Extensions Verified ==="
fi
