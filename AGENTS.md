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
│   ├── export_pois.sql                     # Core DuckDB SQL conversion orchestrator
│   └── sql/                                # Modular DuckDB SQL components
│       ├── 01_taxonomy.sql                 # Taxonomy & category mapping rules loader
│       ├── 02_macros.sql                   # Reusable macros (names, brand, addresses, filters)
│       ├── 03_categorization.sql           # POI category resolution (Single Source of Truth)
│       ├── 04_confidence.sql               # POI confidence scoring model
│       └── 05_relations.sql                # Relation membership & access type resolution macros
└── tests/
    ├── test_conversion.sh                  # Local integration test runner
    └── fixtures/                           # Test PBF fixtures (e.g. Monaco)
```

---

## 3. Critical POI Schema & Conversion Invariants

When modifying or generating code in this repository, you **MUST** follow these domain-specific invariants:

1. **Zero New Heavy Dependencies**:
   * Do not introduce JVM/Java, heavy Python runtimes, or unneeded container images.
   * Everything runs in the existing container `ghcr.io/krizleebear/osm2parquet:v1.0.10` (contains DuckDB + spatial + osmium).
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
    * Relations matching `type IN ('site', 'parking', 'building', 'associatedStreet', 'cluster')` are pre-filtered via `osmium tags-filter` into an in-memory OPL index and joined deterministically (prioritizing `parking` > `site` > `building` > `associatedStreet` > `cluster`).
    * `relation_id`: ID of the parent relation (e.g. `'osm:relation/4109468'`).
    * `member_role`: Role of the member feature within that relation (e.g. `'entrance'`, `'exit'`, `'parking'`, `'perimeter'`, `'outer'`).
    * `parent_osm_id`: Primary POI member of the relation (e.g. the parking area `'osm:way/307701132'`), evaluated distinctly from child access points.
    * `parent_feature_kind`: Kind or category of the parent POI (e.g. `'parking'`, `'site'`, `'building'`).
    * `access_type`: Dedicated access point classification (`'parking'`, `'transit'`, `'pedestrian'`, `'delivery'`, `'emergency'`), resolved via macro `resolve_access_type(...)`. Evaluates to `NULL` for standard non-access POIs.

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
   - Before committing pipeline modifications or scripts, verify execution inside the local Docker container environment (`ghcr.io/krizleebear/osm2parquet:v1.0.10`) to prevent missing-dependency failures in CI runners.
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
31. **Machine-Readable Parquet Metadata & Multi-Tier Attribution Invariant**:
    - Every exported GeoParquet asset must embed full provenance and legal attribution directly into its file footer via DuckDB `KV_METADATA` (`source`, `origin`, `dataset`, `attribution`, `attribution_url`, `license`, `license_url`, `copyright`, `schema`, `schema_url`, `schema_license`, `schema_license_url`, `schema_attribution`, `compiler`, `compiler_version`, `country_code`, `exported_at`).
    - Automated integration tests (`tests/test_conversion.sh`) assert the non-empty presence of `attribution`, `license`, `source`, `compiler`, `country_code`, `schema_license`, and `schema_attribution`.
    - Downstream tools, UI viewers (e.g. `viewer/index.html`), release notes, and documentation must display clear attribution:
      1. OpenStreetMap data conforming to ODbL 1.0 Section 4.3:
         > **"Data © OpenStreetMap contributors, available under the Open Database License (ODbL)."**
         with hyperlinked text pointing to [https://www.openstreetmap.org/copyright](https://www.openstreetmap.org/copyright) and [https://opendatacommons.org/licenses/odbl/](https://opendatacommons.org/licenses/odbl/).
      2. Overture Maps Foundation schema specification conforming to CC-BY-4.0 Section 3(a):
         > **"Schema specification © Overture Maps Foundation, licensed under CC-BY-4.0."**
         with hyperlinked text pointing to [https://overturemaps.org/schema/](https://overturemaps.org/schema/) and [https://creativecommons.org/licenses/by/4.0/](https://creativecommons.org/licenses/by/4.0/).
32. **DuckDB JSONPath & String Quoting Invariant**:
    - In DuckDB `.sql` files, double quotes within single-quoted string literals must NOT be escaped with backslashes. Use `'$."' || k || '"'`, never `'$.\"' || k || '\"'`.
    - DuckDB does not treat backslash as an escape character in standard string literals. Including `\` causes DuckDB to pass a literal backslash into `json_extract_string`, which silently breaks JSONPath key lookup and returns `NULL`.
33. **Public Repository Transition & Legal Compliance Invariant**:
    - Prior to transitioning private repositories to public or publishing open-source releases:
      1. **Multi-Tier Licensing & Disclaimers**:
         - Verify that `LICENSE.md` and `README.md` clearly delineate all four distinct intellectual property tiers:
           - **Pipeline Code**: MIT License.
           - **OSM Data & Parquet Output**: Open Database License (ODbL 1.0) with mandatory attribution and Share-Alike requirements for downstream consumers.
           - **Category Mappings**: MIT License with Cadence Maps (OST) attribution.
           - **Schema Specification**: Creative Commons Attribution 4.0 International (CC-BY-4.0) with Overture Maps Foundation attribution.
      2. **Trademark & Non-Affiliation Disclaimer**:
         - Include an explicit non-affiliation clause in both `LICENSE.md` and `README.md` confirming that "OpenStreetMap" and "Overture Maps" are trademarks of their respective foundations (OSMF and Joint Development Foundation) and that the project is an independent open-source tool.
      3. **Git History Privacy & Security Audit**:
         - Verify via `git log -p` and author log that zero tokens, secrets, personal API keys, or private email addresses exist in commit history.
         - Confirm that no raw binary dumps (`*.pbf`, `*.parquet`) are tracked in git history.
      4. **Container Registry Public Visibility**:
         - Ensure base container images on GHCR (e.g. `ghcr.io/krizleebear/osm2parquet:vX.Y.Z`) have their package visibility configured to **Public**, allowing unauthenticated pulls by external contributors and CI runners.
34. **DuckDB & Arrow Decimal / BLOB Serialization Invariant**:
    - **DuckDB KV Metadata BLOB Keys**: In DuckDB, `parquet_kv_metadata()` returns `key` and `value` as `BLOB`. When consumed through DuckDB-Wasm or Arrow IPC in JavaScript, queries must explicitly cast `SELECT CAST(key AS VARCHAR) AS k, CAST(value AS VARCHAR) AS v` (with defensive `TextDecoder` decoding) to prevent JavaScript object keys from collapsing into `"[object Uint8Array]"`, which causes silent key collisions and missing metadata.
    - **Confidence & Float Scaling (Decimal vs Double)**:
      DuckDB `round(..., 2)` defaults to `DECIMAL(11,2)`. In Apache Arrow IPC, decimals are serialized as raw unscaled integers (e.g. `99` for `0.99`), producing a 100x magnification error (`9900%`) in JavaScript frontends. All normalized ratio and confidence macro outputs must explicitly cast to `::DOUBLE` matching Overture Places schema, and frontend consumers must defensively clamp and scale values (`confVal > 1.0 ? confVal / 100.0 : confVal`).
35. **Spatial Partitioning & Transparent Parquet Merge Invariant (Zero Downstream Breaking Changes)**:
    - **Trigger & Scope**: When an OSM extract is too massive for single-pass streaming within runner RAM constraints (e.g. continental US with 84M+ nodes and 5M+ POIs), the conversion pipeline must partition the extract spatially into bounded sub-regions (e.g. West, Central, East).
    - **Polygon Integrity (`--strategy=complete_ways`)**: All sub-extracts must be generated with `osmium extract -b ... --strategy=complete_ways`. Never cut polygon features or discard relation geometries at bounding-box borders.
    - **Strict Deduplication by Representative Point**: In DuckDB, features must be partitioned using mutually exclusive bounding intervals on `ST_PointOnSurface(geometry)` (e.g. `ST_X(geometry) < -100`, `ST_X >= -100 AND ST_X < -85`, `ST_X >= -85`). Because every point and polygon resolves to exactly one representative surface coordinate, this guarantees **zero cut geometries and zero duplicate POI records across partitions**.
    - **Transparent Parquet Merge**: If the combined GeoParquet output remains safely below the 2.0 GiB GitHub Release ceiling (~380 MB for US), the pipeline runner must merge the partition Parquet files back into the canonical single file (`US_us.places.parquet`) via DuckDB `COPY (SELECT * FROM read_parquet([...])) TO ...`. 
    - **Contract Invariance (Upstream & Downstream)**: Never alter upstream download definitions (`osm-download-pipeline.yml`) or require downstream geocoders/APIs to adapt to fragmented files when a transparent, streaming merge inside the runner can fulfill the contract seamlessly.
    - **Runner Encapsulation**: Encapsulate partitioning, per-partition memory-bounded conversion, and merge execution cleanly inside `scripts/entrypoint.sh` so CI/CD pipeline YAML files (`azure-pipelines.yml`, `templates/convert-steps.yml`) require zero special-casing or matrix branching.
36. **Streaming Memory Optimization & Subquery Cartesian Product Invariant**:
    - **Session Variable Taxonomy Lookup (`getvariable`)**:
      Never use scalar subqueries like `(SELECT lookup FROM taxonomy_lookup)` inside row-level expression macros or `SELECT` lists. DuckDB's query planner evaluates un-correlated scalar subqueries by generating chained `CROSS_PRODUCT` and `HASH_GROUP_BY` operators across vector chunks, buffering streaming records in RAM and causing OOM. Always cache static configuration maps in a DuckDB session variable (`SET VARIABLE taxonomy_lookup = (SELECT lookup FROM taxonomy_lookup);`) and access them via `getvariable('taxonomy_lookup')`, which ensures a 100% streaming physical plan composed exclusively of `PROJECTION` operators.
    - **Disk-Backed Osmium Node Cache (`-i sparse_file_array`)**:
      For large country extracts, `osmium export` default `-i flex_mem` keeps all node coordinates uncompressed in memory (e.g. 1.6+ GB RAM for US 84M nodes). Always specify a disk-backed node cache index `-i "sparse_file_array,${TMP_DIR}/osmium_idx.tmp"` in `scripts/entrypoint.sh` to keep Osmium process memory strictly bounded (< 800 MB).
    - **Multipolygon Buffer Overhead (`maximum_object_size`)**:
      Massive boundary features (such as national parks or nature reserves in large country extracts like the US) can produce single GeoJSON feature strings exceeding 32 MB (up to ~38+ MB). In DuckDB `read_json()`, always configure `maximum_object_size=268435456` (256 MB) to prevent buffer overflow exceptions.
    - **Bounded Execution Concurrency & Parquet Flushing**:
      In memory-constrained CI/CD runners (7.0 GB limit), multi-threaded streaming multiplies JSON string parser buffers. Keep `SET threads = 1` during streaming ingestion, disable order preservation (`SET preserve_insertion_order = false`), and configure aggressive Parquet row group memory bounds (`SET write_buffer_row_group_count = 1; SET write_buffer_row_group_memory_limit = '128MB';`).

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

# Running multiple commands from CLI (use separate -c flags!):
duckdb -dark-mode -no-stdin \
  -c "SET VARIABLE repo_root = '/app';" \
  -c ".read scripts/sql/01_taxonomy.sql" \
  -c "SELECT count(*) FROM taxonomy_lookup;"
```

> [!IMPORTANT]
> - **DuckDB Terminal Probe Timeout (> 5s)**: Always use `-dark-mode -no-stdin` when invoking `duckdb` in CLI commands or test scripts to prevent terminal background color detection timeouts.
> - **Input Redirection vs `.read`**: Because `-no-stdin` disables standard input, piping (`duckdb -no-stdin < script.sql`) closes stdin immediately and exits 0 without running queries. Always execute scripts via `-c ".read script.sql"`.
> - **`.read` is a CLI Dot-Command (NOT SQL)**: `.read` cannot be chained with SQL statements inside a single `-c` flag (e.g. `duckdb -c "SET x=1; .read file.sql"` fails with `Parser Error: syntax error at or near '.'`). Pass separate `-c` flags for each command, or place all commands inside a `.sql` file loaded via a single `-c ".read file.sql"`.
> - **Docker Container Git `safe.directory`**: Because dev containers mount `~/.gitconfig` read-only (`:ro`), `git config --global` fails with resource busy. Always configure `ENV GIT_CONFIG_PARAMETERS="'safe.directory=/app'"` in the Dockerfile / docker-compose environment.

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
