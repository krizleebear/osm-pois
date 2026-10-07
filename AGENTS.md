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
  * **DuckDB Python API** (`duckdb==1.5.5` + `fsspec`) in `scripts/entrypoint.py` for chunked, memory-bounded streaming ingestion.
  * **Osmium-Tool** (`osmium export` and `osmium tags-filter`) for high-throughput pre-filtering and zero-disk streaming of GeoJSON sequences.
  * **Azure DevOps Pipelines** for parallel matrix builds across 150+ countries/regions.
  * **Zero Intermediate Disk I/O**: `scripts/entrypoint.py` streams newline-delimited GeoJSON features from `osmium export` stdout in bounded ~100 MB line-aligned chunks (registered as in-memory `BytesIO` via `duckdb.read_json`), bypassing GDAL's 100 MB SQLite cache limitation and the JSON reader's named-pipe cache OOM while reconstructing 100% of points, ways, and polygons. The CLI/FIFO variant of `scripts/export_pois.sql` remains as reference/pinned by `tests/test_streaming_plan.sh`.

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
│   ├── entrypoint.sh                       # CLI runner script (US split, monitor, validation)
│   ├── entrypoint.py                       # Chunked streaming driver (DuckDB Python API + fsspec)
│   ├── export_pois.sql                     # Core DuckDB SQL conversion orchestrator
│   └── sql/                                # Modular DuckDB SQL components
│       ├── 01_taxonomy.sql                 # Taxonomy & category mapping rules loader
│       ├── 02_macros.sql                   # Reusable macros (names, brand, addresses, filters)
│       ├── 03_categorization.sql           # POI category resolution (Single Source of Truth)
│       ├── 04_confidence.sql               # POI confidence scoring model
│       ├── 05_relations.sql                # Relation membership & access type resolution macros
│       └── 06_places_transform.sql         # places_export transform view (Single Source of Truth)
└── tests/
    ├── test_conversion.sh                  # Local integration test runner
    └── fixtures/                           # Test PBF fixtures (e.g. Monaco)
```

---

## 3. Critical POI Schema & Conversion Invariants

When modifying or generating code in this repository, you **MUST** follow these domain-specific invariants:

1. **Zero New Heavy Dependencies**:
   * Do not introduce JVM/Java, heavy Python runtimes, or unneeded container images.
   * Everything runs in the existing container `ghcr.io/krizleebear/osm2parquet:v1.1.0` (contains DuckDB CLI + Python API + spatial + fsspec + osmium).
2. **Point-on-Surface (No Centroids!)**:
   * For areas, buildings, or relations, **NEVER** use `ST_Centroid()`. Always use `ST_PointOnSurface(geom)` so that the representative coordinate stays within the physical boundary of the feature.
3. **Deterministic Category Precedence**:
   * The mapping table `mappings/overture_to_osm_categories.csv` contains multiple rules for identical primary keys (e.g. `shop=clothes`).
   * When resolving categories in SQL, maintain the single-rule deduplication pattern (`ORDER BY has_subtag ASC, overture_cat ASC`) to ensure deterministic results.
4. **Category Hierarchy Integrity**:
   * `mappings/overture_categories.csv` uses semicolons as column separators (`category;[hierarchy]`). DuckDB's `read_csv` parses this automatically into `column0` and `column1`. Do not use manual string slicing unless necessary.
5. **Multi-Level ODbL License & Provenance Preservation**:
   * **Feature-Level Sources**: In the `sources` array of every generated GeoParquet record, `dataset: 'OpenStreetMap'` and `license: 'ODbL-1.0'` must always be preserved, along with `record_id` (e.g. `osm:node/12345`) and `update_time` (ISO 8601 timestamp).
   * **Feature-Level Versioning**: The top-level `version` column must accurately reflect the OSM feature `@version`.
   * **Parquet File-Level KV_METADATA**: The `COPY ... TO ... (KV_METADATA { ... })` block in `scripts/export_pois.sql` must preserve all machine-readable provenance fields (`source`, `origin`, `dataset`, `attribution`, `attribution_url`, `license`, `license_url`, `copyright`, `schema`, `schema_url`, `schema_license`, `schema_license_url`, `schema_attribution`, `compiler`, `compiler_version`, `country_code`, `exported_at`). Never strip or remove this metadata during refactoring.
6. **Preserve Granularity (No Lossy Over-Generalization)**:
   * Do not map distinct, specialized OSM concepts to broad, inaccurate parent buckets (e.g. `amenity=public_bookcase` MUST NOT be mapped to `library`, `waste_basket` or `bench` must not be force-mapped to unrelated commercial places).
   * It is strictly preferable to preserve the original OSM tag name (e.g. `categories.primary = 'public_bookcase'`) rather than artificially forcing it into an ill-fitting Overture bucket. Downstream systems cannot undo lossy generalizations.
7. **Tag Pipeline Invariant (Filter -> SQL)**:
   * Whenever a new OSM tag or subtag is introduced (e.g. `cuisine`, `railway`, `station`, `operator`):
     1. Ensure it is preserved by `osmium tags-filter` in `azure-pipelines.yml`.
     2. Extract it in `raw_features` and handle it in the category mapping logic in `scripts/sql/03_categorization.sql`.
   * Note: With `osmium export`, all OSM tags are preserved in the JSON `properties` object without requiring manual `config/osmconf.ini` schema adjustments.
8. **Modular DuckDB SQL & Single Source of Truth (`scripts/sql/`)**:
   * The conversion pipeline is decoupled into modular components:
     - `scripts/sql/01_taxonomy.sql`: Loads Overture taxonomy and builds deduplicated mapping rules.
     - `scripts/sql/02_macros.sql`: Encapsulates reusable scalar/table macros (`osm_names_common`, `osm_brand_common`, `is_poi_candidate`, `format_address`, `empty_rules`).
     - `scripts/sql/03_categorization.sql`: Defines `resolve_poi_category(...)`, the Single Source of Truth for POI classification.
     - `scripts/export_pois.sql`: The high-level orchestrator focusing exclusively on streaming ingestion, macro invocation, and Parquet export.
   * **Never Duplicate Categorization Logic**: `tests/test_unit.sql` must directly `.read` and test the production macros in `scripts/sql/`. Never copy-paste `COALESCE` chains or filter expressions into test files.
9. **Micro-Infrastructure vs. POI Guardrail**:
   * Standalone street furniture and micro-infrastructure (`amenity IN ('bench', 'waste_basket', 'shelter', 'grit_bin', 'hunting_stand', 'feeding_place', 'waste_disposal', 'ticket_validator')`) as well as outdoor information micro-infrastructure (`tourism = 'information'` with `information IN ('board', 'guidepost', 'map', 'terminal', 'audioguide', 'tactile_map', 'tactile_model', 'route_marker', 'signpost')`) must **never** be extracted as standalone POIs, even if tagged with a `name` or `operator` (e.g. hiking clubs, transit operators, or municipal park authorities).
   * **Exception 1**: If the feature carries a real primary place tag (e.g. `shop`, `historic`, `office`, `craft`, `healthcare`), it is preserved.
   * **Exception 2 (Physical & Utility Infrastructure POIs — No Synthetic Pseudo-Names, Decoupled Operator)**: High-value physical, municipal, and recreation utility POIs (`amenity IN ('post_box', 'toilets', 'charging_station', 'parking', 'parking_entrance', 'parcel_locker', 'atm', 'drinking_water', 'recycling', 'taxi')`, `leisure=playground`, and `emergency=defibrillator`) are explicitly preserved as POI candidates even if untagged with a `name` or `brand`. They must NEVER receive synthetic pseudo-names or have their `operator` promoted to `names.primary`. If no name or brand is tagged in OSM, `names.primary` must strictly be `NULL`. The service provider is preserved exclusively in the dedicated `operator` column.
   * **Exception 3 (Tourist Info Offices / Visitor Centres)**: `tourism=information` is only categorized as `visitor_center` when explicitly tagged as an office or visitor centre (`information IN ('office', 'visitor_centre', 'visitor_center')`) or when the primary name indicates a tourist info office (e.g. 'Office du Tourisme', 'Tourist Information'). Standalone information boards and trail maps must never be classified as visitor centers.
   * **Exception 4 (Named Man-Made Landmarks)**: `man_made` features qualify as POI candidates ONLY when carrying an explicit name or brand (`name IS NOT NULL OR brand IS NOT NULL`) and when not belonging to micro-technical infrastructure (`surveillance`, `survey_point`, `manhole`, `pipeline`, `pumping_station`, `cutline`, `dyke`, `embankment`, `clearcut`, `flagpole`, `planter`, `street_cabinet`, `water_tap`). This admits prominent navigation anchors (towers, water towers, lighthouses, windmills, observatories, cranes, piers) without ingesting millions of surveillance cameras, utility cabinets, or flagpoles.
   * **Exception 5 (Reference Identifiers & Geocoding Codes)**: The OSM `ref` tag is preserved as an extended operational attribute in the GeoParquet export, enabling downstream geocoders and delivery systems to resolve locker IDs, platform identifiers, and parking facility numbers.
10. **Multilingual `names.common` & `brand.names.common` Extraction**:
    * Localized translations must be extracted dynamically into `MAP(VARCHAR, VARCHAR)` from all `name:<lang>` tags, plus `alt_name` and `int_name`.
    * Non-language and administrative sub-namespaces must be strictly filtered out: `etymology`, `source`, `botanical`, `prefix`, `genitive`, `left`, `right`, `signed`.
    * `brand.names.common` must follow the same `MAP(VARCHAR, VARCHAR)` structure extracted from `brand:<lang>`.
    * Schema conformity: `names.rules` and `brand.names.rules` must strictly be typed as `STRUCT(variant VARCHAR, "language" VARCHAR, perspectives STRUCT("mode" VARCHAR, countries VARCHAR[]), "value" VARCHAR, "between" DOUBLE[], side VARCHAR)[]` (via macro `empty_rules()`).
11. **Generic Raw Tags Extension (`tags MAP(VARCHAR, VARCHAR)`)**:
    * A non-breaking generic `tags MAP(VARCHAR, VARCHAR)` column is appended to the Superset Extension block of `places.parquet`.
    * Contains all unnormalized, unaliased raw OSM tags extracted directly from `properties`.
    * Osmium meta-attributes (`@type`, `@id`, `@version`, `@timestamp`) are strictly excluded via macro `osm_raw_tags(props)`.
    * Evaluates to `NULL` only when a feature carries zero OSM tags.
    * Serves as an open escape hatch for downstream consumers (e.g. EV socket types, capacity, payment apps) without requiring schema adjustments or lossy upstream normalization.
12. **Parent & Relation Membership Attributes (`parent_osm_id`, `parent_feature_kind`, `relation_id`, `member_role`, `access_type`)**:
    * A non-breaking relational superset block is appended to `places.parquet` to represent OSM relation memberships and access topologies without requiring fragile spatial nearest-neighbor joins downstream.
    * Relations matching `type IN ('site', 'parking')` are pre-filtered via `osmium tags-filter` into an in-memory OPL index and joined deterministically (prioritizing `parking` > `site`).
    * `relation_id`: ID of the parent relation (e.g. `'osm:relation/4109468'`).
    * `member_role`: Role of the member feature within that relation (e.g. `'entrance'`, `'exit'`, `'parking'`, `'perimeter'`, `'outer'`).
    * `parent_osm_id`: Primary POI member of the relation (e.g. the parking area `'osm:way/307701132'`), evaluated distinctly from child access points.
    * `parent_feature_kind`: Kind or category of the parent POI (e.g. `'parking'`, `'site'`, `'building'`).
    * `access_type`: Dedicated access point classification (`'parking'`, `'transit'`, `'pedestrian'`, `'delivery'`, `'emergency'`), resolved via macro `resolve_access_type(...)`. Evaluates to `NULL` for standard non-access POIs.
13. **Deterministic Baseline Rule & Subtag Fallback Invariant**:
    * In `mappings/overture_to_osm_categories.csv`, whenever specialized subtag rules are introduced for an OSM tag (e.g. `leisure=track,sport=motor` or `tourism=artwork,artwork_type=mural`), an explicit, non-subtagged baseline rule (`has_subtag = 0`, e.g. `track_and_field_track;leisure=track` or `sculpture_statue;tourism=artwork`) **MUST** be defined.
    * Multiple baseline rules mapping the exact same OSM primary tag (`has_subtag = 0`) to different Overture categories are strictly forbidden, as deterministic alphabetical ordering (`ORDER BY has_subtag ASC, overture_cat ASC`) will cause mass misclassifications (e.g. `bus_station` colliding with `airport_shuttles`).
    * Disambiguate competing rules using explicit secondary tags (e.g. `shuttle=yes`, `association=agriculture`, `tailor=gentlemen`).
14. **Mapping & Taxonomy Deduplication Invariant**:
    * Both `mappings/overture_to_osm_categories.csv` and `mappings/overture_categories.csv` must remain strictly free of duplicate lines and redundant category definitions.
    * Every run of `./tests/run_unit_tests.sh` executes automated integrity assertions (`duplicate_mapping_check` and `duplicate_taxonomy_check`) that immediately fail if duplicates are introduced.

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
   - Before committing pipeline modifications or scripts, verify execution inside the local Docker container environment (`ghcr.io/krizleebear/osm2parquet:v1.1.0`) to prevent missing-dependency failures in CI runners.
10. **Workspace Boundary Scoping**:
    - Limit all grep and file searches strictly to active workspace directories without traversing parent directories.
11. **1-Pass PBF Extraction & Zero-Disk Stream Performance Invariant**:
    - Large raw PBF files must be scanned only ONCE. Avoid multiple redundant reading passes over multi-gigabyte PBF extracts. Ingest `osmium export`'s GeoJSONSeq stdout in bounded line-aligned chunks via `scripts/entrypoint.py` (in-memory `BytesIO` relation per chunk, so `read_json` sees a real size instead of an unsized named pipe whose cache grows with the whole input). Use `osmium tags-filter` for the relations OPL index. Never trigger intermediate disk I/O for the ingest stream.
12. **Token-Efficient Tabular Data Analysis (DuckDB-First Invariant)**:
    - When inspecting or auditing large tabular files (`mappings/*.csv`, `*.parquet`, `*.jsonl`), agents must **NEVER** dump the entire file into the prompt context or rewrite entire files from scratch.
    - Use the DuckDB CLI directly from bash (`duckdb -c "SELECT ... FROM read_csv('mappings/...') ..."`) to filter, aggregate, group, and inspect data out-of-core, returning only concise diagnostic results.
    - Execute modifications surgically using targeted line replacements (`replace_file_content` with `grep -n` target line identification) rather than wholesale file rewrites, minimizing token consumption and preventing context truncation.
13. **Public Repository Transition & Multi-Tier Licensing**:
    - Verify that `LICENSE.md` and `README.md` clearly delineate all four distinct intellectual property tiers: Pipeline Code (MIT), OSM Data & Parquet Output (ODbL 1.0), Category Mappings (MIT), Schema Specification (CC-BY-4.0).
    - Ensure zero secrets, API keys, or private emails are in git history, and no raw binary dumps (`*.pbf`, `*.parquet`) are tracked.
14. **Specialized Architecture & Deep Troubleshooting References**:
    - **CI/CD Pipeline & Runner Memory Tuning**: Read [`docs/azure_pipelines.md`](file:///app/docs/azure_pipelines.md) for Azure DevOps parameter conditions, container entrypoint rules, BufferManager sweet-spot calibration (`max_memory = '4800MB'`), and spatial partitioning.
    - **DuckDB, Arrow IPC & CLI Gotchas**: Read [`docs/duckdb_gotchas.md`](file:///app/docs/duckdb_gotchas.md) for CLI flags (`-dark-mode -no-stdin`), `.read` dot-command rules, Arrow IPC decimal/BLOB serialization, JSONPath quoting, and remote S3 streaming.

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
2. Run `scripts/entrypoint.sh` (which delegates streaming to the chunked Python driver `scripts/entrypoint.py` using DuckDB).
3. Run `tests/test_chunked_streaming.sh`: force 10+ tiny ingest chunks and assert the result is bit-identical (md5) to a single-chunk run, with the KV_METADATA provenance block intact.
4. Assert row count, schema validity, category assignment, and address coverage.

### Ad-hoc Validation with DuckDB

When querying generated parquet files or running SQL scripts, always use non-interactive mode:

```bash
# Querying Parquet:
duckdb -dark-mode -no-stdin -c "SELECT count(*), categories.primary, count(*) FROM 'MC_monaco.places.parquet' GROUP BY ALL LIMIT 10;"

# Executing SQL scripts (NEVER pipe via stdin `< file.sql` when `-no-stdin` is set!):
duckdb -dark-mode -no-stdin -c ".read tests/test_unit.sql"

# Running multiple commands from CLI (use separate -c flags!):
duckdb -dark-mode -no-stdin \
  -c "SET VARIABLE repo_root = '/app';" \
  -c ".read scripts/sql/01_taxonomy.sql" \
  -c "SELECT count(*) FROM taxonomy_lookup;"
```

> [!TIP]
> For critical DuckDB CLI gotchas (`-dark-mode -no-stdin`, `.read` vs piping), Arrow IPC BLOB/Decimal serialization, and direct S3 streaming queries, see [`docs/duckdb_gotchas.md`](file:///app/docs/duckdb_gotchas.md).

---

## 6. Typical Tasks for Agents

* **Extending POI Mapping Rules**: Add new tag combinations to `mappings/overture_to_osm_categories.csv` and ensure matching categories exist in `mappings/overture_categories.csv`.
* **Exposing New OSM Attributes**: If a new tag is needed for categorization or metadata (e.g. `cuisine`, `operator`, `brand`), add it to both `[points]` and `[multipolygons]` in `config/osmconf.ini` AND include it in the `osmium tags-filter` step in `azure-pipelines.yml`.
* **Pipeline Adjustments**: Keep `azure-pipelines.yml` aligned with `scripts/entrypoint.sh`.
