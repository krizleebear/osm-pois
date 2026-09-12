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
  * **Osmium-Tool** (`osmium tags-filter`) for high-throughput pre-filtering of raw OSM PBF data.
  * **Azure DevOps Pipelines** for parallel matrix builds across 150+ countries/regions.
  * **GDAL / OGR OSM Driver** (`config/osmconf.ini`) for schema definition when reading PBF layers (`points`, `multipolygons`).

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

## 3. Critical Invariants & Rules

When modifying or generating code in this repository, you **MUST** follow these rules:

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
7. **Triad Invariant for Tag Additions (Config -> Filter -> SQL)**:
   * Whenever a new OSM tag or subtag is introduced (e.g. `cuisine`, `railway`, `station`, `operator`):
     1. Add it to `[points]` AND `[multipolygons]` in `config/osmconf.ini`.
     2. Add it to `osmium tags-filter` in `azure-pipelines.yml`.
     3. Add it to `raw_features` and category mapping in `scripts/export_pois.sql`.
   * Omitting any of these three steps will cause silent data loss or NULL values.
8. **Azure DevOps Boolean Parameters & Conditions**:
   * Do not use template string expansion like `eq('${{ parameters.x }}', 'true')`. In Azure Pipelines, boolean parameters evaluate at template expansion time to C# capitalized strings (`'True'` / `'False'`), causing equality checks against lowercase `'true'` to fail silently.
   * Always use canonical boolean expression syntax: `eq(parameters.x, true)`.

---

## 4. Verification & Testing

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

## 5. Typical Tasks for Agents

* **Extending POI Mapping Rules**: Add new tag combinations to `mappings/overture_to_osm_categories.csv` and ensure matching categories exist in `mappings/overture_categories.csv`.
* **Exposing New OSM Attributes**: If a new tag is needed for categorization or metadata (e.g. `cuisine`, `operator`, `brand`), add it to both `[points]` and `[multipolygons]` in `config/osmconf.ini` AND include it in the `osmium tags-filter` step in `azure-pipelines.yml`.
* **Pipeline Adjustments**: Keep `azure-pipelines.yml` aligned with `scripts/entrypoint.sh`.
