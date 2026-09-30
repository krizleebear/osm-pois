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

# Verify Azure Pipelines Touchstone DE + US architecture
if [ -f "$REPO_ROOT/azure-pipelines.yml" ]; then
    if ! grep -q 'job: touchstone_germany' "$REPO_ROOT/azure-pipelines.yml"; then
        echo "ERROR: azure-pipelines.yml must define job: touchstone_germany!"
        exit 1
    fi
    if ! grep -q 'job: touchstone_us' "$REPO_ROOT/azure-pipelines.yml"; then
        echo "ERROR: azure-pipelines.yml must define job: touchstone_us!"
        exit 1
    fi
    if ! grep -q 'dependsOn: touchstone_germany' "$REPO_ROOT/azure-pipelines.yml"; then
        echo "ERROR: azure-pipelines.yml touchstone_us must have dependsOn: touchstone_germany!"
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
    if sed -n '/strategy:/,/steps:/p' "$REPO_ROOT/azure-pipelines.yml" | grep -E '^[[:space:]]{8}us:' >/dev/null; then
        echo "ERROR: us must be in dedicated job: touchstone_us, not in convert matrix!"
        exit 1
    fi
    # Ensure preflight container run mounts to /workspace, not /app (which masks container's $HOME/.duckdb extension cache)
    if grep -E 'docker run.*-v.*: */app([[:space:]]|$)' "$REPO_ROOT/azure-pipelines.yml" >/dev/null; then
        echo "ERROR: azure-pipelines.yml preflight must mount repository to /workspace, not /app (masks container's pre-installed .duckdb extensions)!"
        exit 1
    fi
    # Ensure templates/convert-steps.yml does not use buildType: 'current' (which fails when downloading pre-filtered PBFs from earlier builds)
    if grep -q "buildType: 'current'" "$REPO_ROOT/templates/convert-steps.yml"; then
        echo "ERROR: templates/convert-steps.yml must not use buildType: 'current' for prefiltered PBFs (must use buildType: 'specific' from definition 10)!"
        exit 1
    fi
    if ! grep -q 'definition: .10.' "$REPO_ROOT/templates/convert-steps.yml"; then
        echo "ERROR: templates/convert-steps.yml must reference definition 10 for prefiltered POI PBF artifacts!"
        exit 1
    fi
    if ! grep -q 'prefilteredBuildId' "$REPO_ROOT/azure-pipelines.yml"; then
        echo "ERROR: azure-pipelines.yml must define prefilteredBuildId parameter!"
        exit 1
    fi
    # Ensure the JSON reader buffer limit is tokenised (tunable per region) and that the
    # default is large enough to absorb the biggest single GeoJSON record we have ever
    # observed. The continental US produces multipolygon relations of ~38 MB, so 64 MB
    # (67108864 bytes) is the minimum safe default. Larger values are measurably wasteful:
    # DuckDB's read_json pre-allocates several buffers of this size, making it the single
    # largest contributor to the fixed memory floor of the conversion.
    if ! grep -q 'maximum_object_size=__MAX_OBJECT_SIZE__' "$REPO_ROOT/scripts/export_pois.sql"; then
        echo "ERROR: scripts/export_pois.sql must read maximum_object_size from the __MAX_OBJECT_SIZE__ token so regions can tune it!"
        exit 1
    fi
    DEFAULT_MAX_OBJ_SIZE=$(grep -oE 'OSM_POIS_MAX_OBJECT_SIZE:-[0-9]+' "$REPO_ROOT/scripts/entrypoint.sh" | head -1 | grep -oE '[0-9]+$')
    MIN_REQUIRED_OBJ_SIZE=67108864
    if [ -z "$DEFAULT_MAX_OBJ_SIZE" ] || [ "$DEFAULT_MAX_OBJ_SIZE" -lt "$MIN_REQUIRED_OBJ_SIZE" ]; then
        echo "ERROR: OSM_POIS_MAX_OBJECT_SIZE default must be >= $MIN_REQUIRED_OBJ_SIZE (64 MB) to absorb the largest observed OSM GeoJSON record (~38 MB, US multipolygon relations)!"
        exit 1
    fi
    echo "=== [OK] Touchstone DE Pipeline Architecture & Buffer Limits Verified ==="
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
