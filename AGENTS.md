# AGENTS.md — Development & Contributor Guidelines for Autonomous Agents

Welcome to **osm-pois**. This repository maintains an automated worldwide OpenStreetMap (OSM) to Overture Places-compatible GeoParquet compiler pipeline.

This document guides AI coding agents (such as Antigravity CLI / `agy`, OpenCode, Claude Code, Cursor) and human contributors when working on this codebase.

---

## 1. Project Overview & Architecture

* **Primary Purpose**: Transforms raw OpenStreetMap PBF dumps (`*.osm.pbf`) into cloud-optimized GeoParquet files (`places.parquet`) strictly conforming to the official **Overture Maps `theme=places / type=place`** schema.
* **Scope & Mission**: 
  * Unlike specialized upstream subsets (such as `UPSTREAM_CONTRACT_OSM_HIGH_PRIORITY_POIS.md` which only extracts Tier 1 & Tier 2 landmark POIs for downstream geocoding), **`osm-pois` is designed as a full, comprehensive, drop-in open alternative to the entire Overture Places dataset**.
  * It compiles **ALL points of interest** across all commercial, social, cultural, administrative, and service tiers (restaurants, shops, offices, crafts, healthcare, tourism, leisure, services, transport, etc.) into the Overture schema.
* **Core Technology Stack**:
  * **DuckDB CLI** with `spatial` and `httpfs` extensions (SQL-based transformations, zero Java/JVM dependencies).
  * **Osmium-Tool** (`osmium export` and `osmium tags-filter`) for high-throughput pre-filtering and zero-disk streaming of GeoJSON sequences via FIFO pipes directly into DuckDB.
  * **Azure DevOps Pipelines** for parallel matrix builds across 150+ countries/regions.
  * **Zero Intermediate Disk I/O**: `osmium export` streams newline-delimited GeoJSON features directly into DuckDB via a named pipe (`mkfifo`), bypassing GDAL's 100 MB SQLite cache limitation and reconstructing 100% of points, ways, and polygons.

---

## 2. Directory Structure & Key Files

```
osm-pois/
├── AGENTS.md                               # This file (guidelines for autonomous agents)
├── README.md                               # Project documentation & quickstart
├── azure-pipelines.yml                     # Production CI/CD matrix pipeline
├── config/
│   └── osmconf.ini                         # GDAL OSM driver configuration (extracted attributes)
├── mappings/
│   ├── overture_categories.csv             # Overture taxonomy categories & hierarchical path
│   ├── overture_to_osm_categories.csv      # 2,100+ OSM tag rules mapped to Overture categories
│   └── README.md                           # Provenance & license info for category mappings
├── scripts/
│   ├── entrypoint.sh                       # CLI runner script for DuckDB conversion
│   └── export_pois.sql                     # Core DuckDB SQL conversion logic
└── tests/
    ├── test_conversion.sh                  # Local integration test runner
    └── fixtures/                           # Test PBF fixtures (e.g. Monaco)
```

---

## 3. Critical POI Schema & Conversion Invariants

When modifying or generating code in this repository, you **MUST** follow these domain-specific invariants:

1. **Zero New Heavy Dependencies**:
   * Do not introduce JVM/Java, heavy Python runtimes, or unneeded container images.
   * Everything runs in the existing container `ghcr.io/krizleebear/osm2parquet:v1.0.9` (contains DuckDB + spatial + osmium).
2. **Point-on-Surface (No Centroids!)**:
   * For areas, buildings, or relations, **NEVER** use `ST_Centroid()`. Always use `ST_PointOnSurface(geom)` so that the representative coordinate stays within the physical boundary of the feature.
3. **Deterministic Category Precedence**:
   * The mapping table `mappings/overture_to_osm_categories.csv` contains multiple rules for identical primary keys (e.g. `shop=clothes`).
   * When resolving categories in SQL, maintain the single-rule deduplication pattern (`ORDER BY has_subtag ASC, overture_cat ASC`) to ensure deterministic results.
4. **Category Hierarchy Integrity**:
   * `mappings/overture_categories.csv` uses semicolons as column separators (`category;[hierarchy]`). DuckDB's `read_csv` parses this automatically into `column0` and `column1`. Do not use manual string slicing unless necessary.
5. **ODbL License Preservation**:
   * In the `sources` array of the generated GeoParquet, `dataset: 'OpenStreetMap'` and `license: 'ODbL-1.0'` must always be preserved.
6. **Preserve Granularity (No Lossy Over-Generalization)**:
   * Do not map distinct, specialized OSM concepts to broad, inaccurate parent buckets (e.g. `amenity=public_bookcase` MUST NOT be mapped to `library`, `waste_basket` or `bench` must not be force-mapped to unrelated commercial places).
   * It is strictly preferable to preserve the original OSM tag name (e.g. `categories.primary = 'public_bookcase'`) rather than artificially forcing it into an ill-fitting Overture bucket. Downstream systems cannot undo lossy generalizations.
7. **Tag Pipeline Invariant (Filter -> SQL)**:
   * Whenever a new OSM tag or subtag is introduced (e.g. `cuisine`, `railway`, `station`, `operator`):
     1. Ensure it is preserved by `osmium tags-filter` in `azure-pipelines.yml`.
     2. Extract it in `raw_features` and handle it in the category mapping logic in `scripts/export_pois.sql`.
   * Note: With `osmium export`, all OSM tags are preserved in the JSON `properties` object without requiring manual `config/osmconf.ini` schema adjustments.

---

## 4. Git Workflow & Pipeline Invariants

To ensure consistent pipeline execution, reproducible releases, and clean Git workflows across the OSM compiler pipeline ecosystem, developers and AI agents must adhere to the following rules:

1. **Explanation Preceding Git Actions Invariant (Explain First, Commit Second)**:
   - The agent must always first present a clear, comprehensive explanation of the diagnosis, the rationale, and the exact changes in the visible response text before requesting permission or attempting to execute `git commit`, `git push`, or pipeline triggers. Never trigger permission prompts for Git actions without the user having seen the complete explanatory context first.
2. **Atomic Commits & Mandatory Test Expansion**:
   - **Mandatory Test Coverage**: Whenever adding a new feature, new category mapping, or fixing a bug, you **MUST** extend the test suite (e.g. add new test cases in `tests/test_unit.sql` or add validation assertions in `tests/test_conversion.sh`).
   - **Immediate Atomic Commits**: As soon as a feature, fix, or logical task is completed and verified (`./tests/run_unit_tests.sh` and/or `./tests/test_conversion.sh` pass), immediately create a clean Git commit with a conventional commit message.
   - **No Uncommitted Work Pile-up**: Never leave multiple unrelated features uncommitted in the working tree. Commit each topic separately once green.
3. **Diff Verification against Remote**:
   - Before committing or pushing, verify `git diff origin/main` to ensure no local test comments, temporary debug code, or scratch files are staged.
4. **Conventional Commits**:
   - Use conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`).
5. **Language Preference Hierarchy for Scripts & Tools**:
   - Select implementation languages based on the available lightweight execution environment following the strict priority hierarchy: **DuckDB SQL > Python 3 > Bash > others**.
   - Zero JVM/Java dependencies is a non-negotiable project invariant. Do not introduce unapproved secondary languages outside this hierarchy.
6. **Transparent Failure Policy (No Hiding Errors / No Silent Fallbacks)**:
   - Pipeline scripts and processing stages must never mask missing input artifacts, swallow errors, or execute silent fallbacks to raw external URLs. If an expected upstream artifact or file is missing, the script must fail explicitly with a clear, diagnostic error message detailing the missing file, root cause, and remediation steps.
7. **English Output Standard for CI/CD & Pipeline Logs**:
   - All user-facing log outputs, diagnostic error messages, pipeline notices, and CLI reports must be written strictly in clear, professional English to maintain consistency across international developer environments and automated CI/CD runners.
8. **Container Security & Dependency Invariance (No Root Elevation / No Dynamic Package Install)**:
   - Pipeline steps and container configurations must strictly run unprivileged and must NEVER escalate to root permissions (`--user 0:0` or `sudo`) to bypass container limitations. All required execution binaries (e.g. Python 3, DuckDB, Osmium) must be pre-packaged directly in the container image, and pipeline steps must never perform dynamic runtime package installation (`apt-get install`).
9. **Local Clean-Room Container Verification**:
   - Before committing pipeline modifications or scripts, verify execution inside the local Docker container environment (`ghcr.io/krizleebear/osm2parquet:v1.0.9`) to prevent missing-dependency failures in CI runners.
10. **Workspace Boundary Scoping**:
    - Limit all grep and file searches strictly to active workspace directories without traversing parent directories.
11. **Mandatory Pipeline YAML Syntax Pre-Verification**:
    - Before committing modifications to pipeline definition files (`.yml`), validate full YAML structural parsing inside Docker or local Python (e.g. `python3 -c "import yaml; yaml.safe_load(open('azure-pipelines.yml'))"`). Commits with unverified YAML syntax are strictly prohibited.
12. **Azure DevOps Job Container Entrypoint Safety**:
    - Docker images intended for Azure DevOps job containers (`container: <image>`) must NOT define an exec-form `ENTRYPOINT` that exits on unknown arguments (such as `ENTRYPOINT ["/app/entrypoint.sh"]`), because Azure DevOps starts job containers with `sleep infinity`. Use `CMD ["/bin/bash"]` in the Dockerfile and invoke processing scripts explicitly in pipeline steps.
13. **Docker Schema 2 Manifest Requirement for Container Registries**:
    - Container images pushed to Docker Hub or `mirror.gcr.io` consumption must be built in Docker Schema 2 format (`application/vnd.docker.distribution.manifest.v2+json`) using standard `docker build` or `docker buildx build --provenance=false`. Modern OCI attestation/provenance blobs cause `unknown blob` 404 errors on `mirror.gcr.io`.
14. **DuckDB Script Template Substitution Invariant**:
    - DuckDB `COPY ... TO` statements require string literal paths. Do not attempt `getvariable()` inside `COPY TO`. Use `sed` token substitution (`__INPUT_JSONL__`, `__OUTPUT_PARQUET__`, `__COUNTRY_CODE__`, `__REPO_ROOT__`) on SQL templates before piping into `duckdb`.
15. **Azure DevOps Boolean & Parameter Condition Syntax**:
    - In Azure DevOps task/job/stage `condition:` expressions, template parameters are NOT accessible directly as runtime variables (`parameters.x`) and MUST be evaluated inside template expressions: `${{ eq(parameters.x, true) }}`. Referencing raw `parameters.x` outside of `${{ }}` causes `Unrecognized value: 'parameters'` errors at pipeline initialization.
    - Do not use string expansion like `eq('${{ parameters.x }}', 'true')` because boolean parameters evaluate at template expansion time to C# capitalized strings (`'True'` / `'False'`), causing checks against lowercase `'true'` to fail silently. Always wrap the boolean expression in `${{ eq(parameters.x, true) }}`.
    - In Bash scripts, handle both `"false"` and `"False"` because template expansion converts boolean false to `"False"`.
16. **Azure DevOps String Parameter Defaults (`latest` / `auto`)**:
    - In Azure DevOps manual run dialogs, string parameters treat empty string values as invalid/required in the UI modal. String parameters (like `downloadBuildId`) must default to `'latest'` or `'auto'`, and conditions must support `'latest'`, `'auto'`, and custom build IDs.
17. **Downstream Stage Dependency Safety (`condition: succeeded('<stage>')`)**:
    - Downstream stages (such as release or aggregation) that depend on upstream parallel matrix jobs MUST use `condition: succeeded('<stage>')`. Using parameterless `succeeded()` causes the stage to be skipped if any upstream stage was skipped via conditional parameters. Never use `condition: always()` on final bundling/release stages, as upstream failure would trigger incomplete artifact archiving.
18. **Container Registry Mirrors & Upstream Image Synchronization**:
    - Preserve primary registry configurations (GHCR) and fallback mirrors (`mirror.gcr.io`) in pipeline definitions. Whenever the base container image (`osm2parquet`) is updated, downstream pipeline definitions (`azure-pipelines.yml`) must immediately reference the new tag.
19. **Feature Branch Pipeline Testing**:
    - Azure DevOps pipelines can be triggered directly from feature branches. For major pipeline refactorings or matrix tests, work and test on a dedicated feature branch first before merging to `main`.
20. **Fast-Fail CI Preflight Invariant**:
    - Never launch long-running or matrix-heavy pipeline stages without an initial fast (<30s) preflight check or stage. Validate pipeline YAML syntax and execute the fast unit test suite (`./tests/run_unit_tests.sh`) before heavy runner compute is consumed.
21. **Guaranteed Artifact Existence Invariant**:
    - Azure DevOps `PublishPipelineArtifact` tasks fail with runner warnings if the target file does not exist on disk. Export jobs and post-processing steps must ensure all declared artifact targets exist (touching empty fallback files if necessary) to keep build results 100% clean and green.
22. **Non-Breaking Pipeline Quality Audits (`##vso[task.logissue type=warning]`)**:
    - Post-processing data audits (such as category coverage checks, feature count assertions, or empty dataset checks) should emit native Azure DevOps warning annotations (`echo "##vso[task.logissue type=warning]..."`) and run with `continueOnError: true` unless hard-failing is strictly required. This highlights anomalies prominently in the Azure DevOps run summary without breaking long-running packaging pipelines.
23. **Modular & Testable Validation Tooling**:
    - Complex verification steps must never be written as long inline Bash loops inside pipeline YAML. Implement them as dedicated, standalone scripts (e.g. in `tests/` or `scripts/`) with accompanying test cases runnable in local Docker environments.
24. **Long-Form CLI Parameters & Download Resilience Invariant**:
    - Always use explicit, readable long-form parameters in pipeline scripts (e.g., `--continue-at -` instead of `-C -`).
    - Large external file downloads (such as Geofabrik PBF extracts) must specify stall timeouts (`--speed-limit 10240 --speed-time 30`), resume capabilities (`--continue-at -`), and emit lightweight background progress heartbeats to prevent silent runner hangs.
25. **1-Pass PBF Extraction & Zero-Disk Stream Performance Invariant**:
    - Large raw PBF files must be scanned only ONCE. Avoid multiple redundant reading passes over multi-gigabyte PBF extracts. Use `osmium export` or `osmium tags-filter` streaming directly through named pipes (`mkfifo`) into DuckDB to eliminate intermediate disk I/O.
26. **Osmium Export ID & Provenance Configuration Invariant**:
    - `osmium export` omits `@id`, `@version`, and `@timestamp` attributes by default unless `--config` or `-a type,id,version,timestamp` is explicitly passed. All place export commands must pass `-a type,id,version,timestamp` (or `--attributes=type,id,version,timestamp`) to preserve `osm_id`, feature version, and edit timestamps for provenance.
27. **Stream File Format Conventions (`.geojsonseq` vs `.jsonl`) & Vectorized DuckDB Ingestion**:
    - `*.geojsonseq`: Strictly adheres to RFC 8142 (GeoJSON Text Sequences) where each line is a full standard GeoJSON Feature object (`{"type": "Feature", "geometry": {...}, "properties": {...}}`). Designed for spatial streaming.
    - `*.jsonl`: Formatted as newline-delimited flattened tabular records. Designed as high-throughput, columnar-ready ETL streams for direct vectorized ingestion via DuckDB `read_json()`. Tabular JSONL streams must retain `.jsonl` and never be misnamed `.geojsonseq` as they lack GeoJSON Feature wrappers.
28. **Multi-Extract Feature Deduplication Invariant**:
    - When consolidating multiple regional extracts into a single per-country GeoParquet file (e.g. Spain + Canary Islands), DuckDB consolidation queries must deduplicate shared features using `ROW_NUMBER() OVER (PARTITION BY id ORDER BY ...)` or deterministic precedence.
29. **GitHub Release 2 GiB Asset Size Limit & GeoParquet Partitioning**:
    - GitHub Releases enforce a strict hard limit of 2 GiB (2,147,483,648 bytes) per uploaded asset. Regional GeoParquet files must stay safely under 2.0 GiB (partitioning large countries if necessary).
30. **Evidence-Based Issue Analysis & Remote Diagnostics (DuckDB + httpfs / S3)**:
    - Never assume an issue is fixed or make claims based solely on commit history, code reviews, or theoretical assumptions. Always gather concrete empirical evidence by directly querying live release artifacts or test outputs.
    - Use DuckDB with `httpfs` to query remote GitHub Release assets or S3 buckets directly (`duckdb -c "INSTALL httpfs; LOAD httpfs; SELECT ... FROM 'https://...'"`).
    - When reporting or investigating anomalies across upstream/downstream boundaries, provide reproducible SQL queries against the exact release dataset to eliminate ambiguity and immediately isolate root causes.

---

## 5. Verification & Testing

### Running Unit Tests & Taxonomy Linter (<100ms)

Verify mapping consistency and category resolution logic without needing PBF files:

```bash
./tests/run_unit_tests.sh
```

This will:
1. Lint `mappings/overture_to_osm_categories.csv` against `mappings/overture_categories.csv` (asserts 0 orphaned categories, 0 malformed rows).
2. Execute 33+ deterministic mock test cases against the core SQL categorization logic.

### Running the Integration Test

Verify end-to-end PBF-to-GeoParquet conversion:

```bash
./tests/test_conversion.sh
```

This will:
1. Ensure the Monaco sample PBF fixture exists (or downloads it if missing).
2. Run `scripts/entrypoint.sh` using DuckDB.
3. Assert row count, schema validity, category assignment, and address coverage.

### Ad-hoc Validation with DuckDB

When querying generated parquet files or running SQL scripts, always use non-interactive mode:

```bash
# Querying Parquet:
duckdb -dark-mode -no-stdin -c "SELECT count(*), categories.primary, count(*) FROM 'MC_monaco.places.parquet' GROUP BY ALL LIMIT 10;"

# Executing SQL scripts (NEVER pipe via stdin `< file.sql` when `-no-stdin` is set!):
duckdb -dark-mode -no-stdin -c ".read tests/test_unit.sql"
```

> [!IMPORTANT]
> - Always use `-dark-mode -no-stdin` when invoking `duckdb` in CLI commands or test scripts to prevent terminal color detection timeouts (> 5s).
> - Because `-no-stdin` disables standard input, piping (`duckdb -no-stdin < script.sql`) fails silently. Always use `-c ".read script.sql"`.

### Querying Official Overture Data Directly (S3 Streaming)

For coverage benchmarks or taxonomy comparisons against official Overture releases, stream directly via DuckDB without downloading full dumps:

```sql
-- Configure anonymous access to Overture public S3 bucket
CREATE SECRET overture (TYPE S3, KEY_ID '', SECRET '', REGION 'us-west-2');

-- Leverage bbox metadata / part files for high-throughput spatial pruning (e.g. Germany is in part-00010 & part-00011):
SELECT count(*), categories.primary
FROM read_parquet('s3://overturemaps-us-west-2/release/2026-08-19.0/theme=places/type=place/*')
WHERE bbox.xmin >= 5.86 AND bbox.xmax <= 15.04
  AND bbox.ymin >= 47.27 AND bbox.ymax <= 55.06
  AND addresses[1].country = 'DE'
GROUP BY ALL;
```

---

## 6. Typical Tasks for Agents

* **Extending POI Mapping Rules**: Add new tag combinations to `mappings/overture_to_osm_categories.csv` and ensure matching categories exist in `mappings/overture_categories.csv`.
* **Exposing New OSM Attributes**: If a new tag is needed for categorization or metadata (e.g. `cuisine`, `operator`, `brand`), add it to both `[points]` and `[multipolygons]` in `config/osmconf.ini` AND include it in the `osmium tags-filter` step in `azure-pipelines.yml`.
* **Pipeline Adjustments**: Keep `azure-pipelines.yml` aligned with `scripts/entrypoint.sh`.
