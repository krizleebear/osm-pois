# Azure DevOps CI/CD & Pipeline Infrastructure Guide

This document captures the production CI/CD architecture, container specifications, and high-throughput memory calibration rules for the worldwide `osm-pois` build pipeline (`azure-pipelines.yml`).

---

## 1. Azure DevOps Syntax & Template Expressions

### 1.1. Boolean & Parameter Condition Syntax
* In Azure DevOps task/job/stage `condition:` expressions, template parameters are **NOT** accessible directly as runtime variables (`parameters.x`) and **MUST** be evaluated inside template expressions: `${{ eq(parameters.x, true) }}`. Referencing raw `parameters.x` outside of `${{ }}` causes `Unrecognized value: 'parameters'` errors at pipeline initialization.
* Do not use string expansion like `eq('${{ parameters.x }}', 'true')` because boolean parameters evaluate at template expansion time to C# capitalized strings (`'True'` / `'False'`), causing checks against lowercase `'true'` to fail silently. Always wrap the boolean expression in `${{ eq(parameters.x, true) }}`.
* In Bash scripts, handle both `"false"` and `"False"` because template expansion converts boolean false to `"False"`.

### 1.2. String Parameter Defaults (`latest` / `auto`)
* In Azure DevOps manual run dialogs, string parameters treat empty string values as invalid/required in the UI modal. String parameters (like `downloadBuildId`) must default to `'latest'` or `'auto'`, and conditions must support `'latest'`, `'auto'`, and custom build IDs.

### 1.3. Downstream Stage Dependency Safety (`condition: succeeded('<stage>')`)
* Downstream stages (such as release or aggregation) that depend on upstream parallel matrix jobs MUST use `condition: succeeded('<stage>')`.
* Using parameterless `succeeded()` causes the stage to be skipped if any upstream stage was skipped via conditional parameters.
* Never use `condition: always()` on final bundling/release stages, as upstream failure would trigger incomplete artifact archiving.

### 1.4. Fast-Fail CI Preflight Invariant
* Never launch long-running or matrix-heavy pipeline stages without an initial fast (<30s) preflight check or stage. Validate pipeline YAML syntax and execute the fast unit test suite (`./tests/run_unit_tests.sh`) before heavy runner compute is consumed.

### 1.5. Guaranteed Artifact Existence
* Azure DevOps `PublishPipelineArtifact` tasks fail with runner warnings if the target file does not exist on disk. Export jobs and post-processing steps must ensure all declared artifact targets exist (touching empty fallback files if necessary) to keep build results 100% clean and green.

### 1.6. Non-Breaking Pipeline Quality Audits (`##vso[task.logissue type=warning]`)
* Post-processing data audits (such as category coverage checks, feature count assertions, or empty dataset checks) should emit native Azure DevOps warning annotations (`echo "##vso[task.logissue type=warning]..."`) and run with `continueOnError: true` unless hard-failing is strictly required. This highlights anomalies prominently in the Azure DevOps run summary without breaking long-running packaging pipelines.

---

## 2. Container Execution & Security

### 2.1. Unprivileged Execution (No Root Elevation / No Dynamic Package Install)
* Pipeline steps and container configurations must strictly run unprivileged and must **NEVER** escalate to root permissions (`--user 0:0` or `sudo`) to bypass container limitations.
* All required execution binaries (Python 3, DuckDB, Osmium) must be pre-packaged directly in the container image (`ghcr.io/krizleebear/osm2parquet:v1.0.10`). Pipeline steps must never perform dynamic runtime package installation (`apt-get install`).

### 2.2. Azure DevOps Job Container Entrypoint Safety
* Docker images intended for Azure DevOps job containers (`container: <image>`) must **NOT** define an exec-form `ENTRYPOINT` that exits on unknown arguments (such as `ENTRYPOINT ["/app/entrypoint.sh"]`), because Azure DevOps starts job containers with `sleep infinity`.
* Use `CMD ["/bin/bash"]` in the Dockerfile and invoke processing scripts explicitly in pipeline steps.

### 2.3. Docker Schema 2 Manifest Requirement
* Container images pushed to Docker Hub or `mirror.gcr.io` consumption must be built in Docker Schema 2 format (`application/vnd.docker.distribution.manifest.v2+json`) using standard `docker build` or `docker buildx build --provenance=false`. Modern OCI attestation/provenance blobs cause `unknown blob` 404 errors on `mirror.gcr.io`.

### 2.4. Container Registry Mirrors & Upstream Image Synchronization
* Preserve primary registry configurations (GHCR) and fallback mirrors (`mirror.gcr.io`) in pipeline definitions. Whenever the base container image (`osm2parquet`) is updated, downstream pipeline definitions (`azure-pipelines.yml`) must immediately reference the new tag.

---

## 3. High-Throughput Streaming & Memory Calibration

### 3.1. Calibrated Production Values on 7.0 GB Runners
On large country extracts (e.g. Germany with 8.3M OSM features → 3.18M POIs), DuckDB's active working set requires ~4.5 GB peak RSS.
* **The Under-Allocation Trap**: Capping `max_memory` too tightly (e.g. 2600 MB or 3400 MB) does *not* force DuckDB to use less memory. Instead, DuckDB fills its buffer pool up to `max_memory - atomic_chunk_size`, at which point the next atomic 127.9 MiB buffer allocation fails with `OutOfMemoryError: failed to allocate data of size 127.9 MiB`.
* **The Over-Allocation Trap**: Setting `max_memory` too high (> 5200 MB) triggers the Linux container OOM killer (Exit Code 137 / SIGKILL) on Azure DevOps runners when combined with Osmium's peak memory.
* **Calibrated Production Value**:
  ```sql
  SET max_memory = '4800MB';
  SET threads = 1;
  SET preserve_insertion_order = false;
  SET enable_external_file_cache = false;
  SET write_buffer_row_group_count = 1;
  SET write_buffer_row_group_memory_limit = '64MB';
  ```
  In a 7.0 GB Azure DevOps container:
  * Osmium (`osmium export -i sparse_file_array`): ~116 MB during node export, peaks at ~730 MB when resolving relation geometries from disk.
  * DuckDB (`read_json`, projections, relations join, Parquet write): peaks at ~4.5–4.7 GB RSS.
  * Combined peak container RSS: ~5.4 GB / 7.0 GB, leaving ~1.6 GB headroom for kernel and pipe buffers.

### 3.2. Disk-Backed Osmium Node Cache (`-i sparse_file_array`)
* For large country extracts, `osmium export` default `-i flex_mem` keeps all node coordinates uncompressed in memory (e.g. 1.6+ GB RAM for US 84M nodes). Always specify a disk-backed node cache index `-i "sparse_file_array,${TMP_DIR}/osmium_idx.tmp"` in `scripts/entrypoint.sh` to keep Osmium process memory strictly bounded (< 800 MB).

### 3.3. Reader Memory Floor (`maximum_object_size`)
* Boundary relations in continental extracts can produce single GeoJSON feature strings exceeding 32 MB.
* `read_json(..., maximum_object_size=N)` causes DuckDB to pre-allocate stream buffers sized at 2 × N. At N = 64 MB (`67108864`), the reader allocates 128 MB (`127.9 MiB`) chunks with a ~490 MB RSS floor, providing safety without OOM. The value is configured via `__MAX_OBJECT_SIZE__`.

### 3.4. Mandatory 100% Streaming Pipeline (No Blocking Window Operators)
* Global window functions (such as `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)`) force DuckDB to collect and materialize the entire multi-million row dataset in memory before writing a single row group, triggering instant OOM.
* Apply `is_poi_candidate(properties)` and `geometry IS NOT NULL` directly inside the `read_json` scan so non-POI features are discarded while still in raw JSON strings.

### 3.5. Session Variable Taxonomy Lookup (`getvariable`)
* Never use scalar subqueries like `(SELECT lookup FROM taxonomy_lookup)` inside row-level expression macros or `SELECT` lists. DuckDB's query planner evaluates un-correlated scalar subqueries by generating chained `CROSS_PRODUCT` and `HASH_GROUP_BY` operators across vector chunks, buffering streaming records in RAM and causing OOM.
* Always cache static configuration maps in a DuckDB session variable:
  ```sql
  SET VARIABLE taxonomy_lookup = (SELECT lookup FROM taxonomy_lookup);
  ```
  and access them via `getvariable('taxonomy_lookup')`, which guarantees a 100% streaming physical plan composed exclusively of `PROJECTION` operators.

---

## 4. Spatial Partitioning & Transparent Parquet Merge

When an OSM extract is too massive for single-pass streaming within runner RAM constraints (e.g. continental US with 84M+ nodes and 5M+ POIs):
1. **Bounded Sub-Regions**: Partition the extract spatially using `osmium extract -b ... --strategy=complete_ways`. Never cut polygon features or discard relation geometries at borders.
2. **Strict Deduplication by Representative Point**: In DuckDB, partition features using mutually exclusive bounding intervals on `ST_PointOnSurface(geometry)` (e.g. `ST_X(geometry) < -100`, `ST_X >= -100 AND ST_X < -85`, `ST_X >= -85`). Because every point and polygon resolves to exactly one representative surface coordinate, this guarantees **zero cut geometries and zero duplicate POI records across partitions**.
3. **Transparent Parquet Merge**: If the combined GeoParquet output remains safely below the 2.0 GiB GitHub Release ceiling (~380 MB for US), merge partition files back into the canonical single file (`US_us.places.parquet`) via DuckDB `COPY (SELECT * FROM read_parquet([...])) TO ...`. Encapsulate this cleanly inside `scripts/entrypoint.sh` so CI/CD pipeline YAML requires zero matrix branching.

---

## 5. Download Resilience & Large Extracts
* Large external file downloads (such as Geofabrik PBF extracts) must specify stall timeouts (`--speed-limit 10240 --speed-time 30`), resume capabilities (`--continue-at -`), and emit lightweight background progress heartbeats to prevent silent runner hangs.
* Always use explicit, readable long-form parameters in pipeline scripts (e.g. `--continue-at -` instead of `-C -`).
