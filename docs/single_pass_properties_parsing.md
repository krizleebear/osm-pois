# Plan: Single-Pass OSM Properties Parsing (Taiwan OOM)

Status: **implemented & validated** — see [§7 Implementation Results](#7-implementation-results).
Branch base: `feat/chunked-python-streaming` (commit `8255b40`).
Trigger: Azure DevOps build 454, job `PBF -> Parquet taiwan` — the only failure out of 175 jobs
(US, DE, FR, RU succeeded).

## 1. Problem

```
[STAGE 2/4] Streaming osmium export through chunked Python driver (chunk size: 104857600 bytes)...
[FATAL] Out of Memory Error: failed to allocate data of size 16.0 MiB (4.4 GiB/4.4 GiB used)
```

The very first 100 MB chunk dies inside `INSERT INTO stage SELECT * FROM places_export`
(no `[CHUNK 1]` line is ever printed). `4.4 GiB` == `SET max_memory = '4800MB'`.

### 1.1 Local reproduction (CI image `ghcr.io/krizleebear/osm2parquet:v1.1.0`, DuckDB 1.5.5)

Input: geofabrik `taiwan-latest.osm.pbf` (327 MB) -> CI `tags-filter` -> `TW_taiwan.pois.pbf` (28 MB)
-> `osmium export` -> 207 MB GeoJSONSeq, 425k features.

| Probe on first 100 MB chunk (229k features, all points)          | Peak RSS     |
|------------------------------------------------------------------|--------------|
| `read_json` only / `ST_GeomFromGeoJSON` / `ST_IsValid` / `ST_PointOnSurface` / `osm_area_sqm` | ~520 MB |
| `WHERE is_poi_candidate(properties)` only                        | **1.7 GB**   |
| `COPY (SELECT * FROM places_export)` / `INSERT` / even `count(id)` | **OOM** at 4.4 GiB |
| same, `max_memory = 10GB`                                         | 4.2 GB peak, 168k rows |
| full pipeline with `OSM_POIS_CHUNK_BYTES=10485760` (10 MB)        | passes, 255k POIs, 117 s, but RSS still up to 2.4 GB for 10 MB of JSON |

Ruled out:
- **Giant geometries** — largest record in all of Taiwan is 180 KB (nature reserve multipolygons);
  the failing chunk contains only points.
- **Staging / COPY** — a plain streaming `COPY` of the view fails identically.

Not yet isolated: the `LEFT JOIN osm_relation_members` contribution (the filter alone already
costs 1.7 GB without any join, so it is not the primary driver) — measure in Phase 0.

### 1.2 Root cause

The transform re-parses the full `properties` JSON document for every tag access:

- ~250 static `json_extract_string(props, '$.<key>')` calls (78 distinct keys) across
  `02_macros.sql` (151), `04_confidence.sql` (36), `06_places_transform.sql` (64).
  Macros are inlined, and `is_poi_candidate` is evaluated twice (`base_json` and `valid_geoms`),
  so the effective number of parses per row is far higher.
- Key-iterating macros are **quadratic in tag count**: `osm_name_keys`, `osm_brand_keys`,
  `osm_raw_tags`, `osm_name_rule_keys`, `extract_payment_methods`, lifecycle checks iterate
  `json_keys(props)` and call `json_extract_string` (= full re-parse) **per key**.
  `osm_raw_keys` is evaluated 3x inside `osm_raw_tags`, `osm_name_keys` 2x inside `osm_names_common`.

Per-row cost ~ `#tags x document size`; per-chunk memory ~ `rows per chunk x per-row cost`.

### 1.3 Why Taiwan and not the US

Chunks are **byte**-bounded, staging is disk-backed — total country size is irrelevant, only the
cost of one chunk matters. Taiwan maximises both factors:

- **Density**: 229k features per 100 MB, 73 % (168k) pass the candidate filter.
- **Tag richness**: multilingual names (`name`, `name:zh`, `name:zh-Hant`, `name:zh-Hans`,
  `name:en`, `name:ja`, ...) — 71 MB of the 100 MB chunk are properties text; CJK is 3 bytes/char.

Hypothesis to confirm in Phase 0: US/DE/FR chunks have far fewer qualifying rows and tags per row.

## 2. Goal / Non-Goals

Goal: parse each feature's properties **exactly once**, make per-row cost linear in tag count,
and bring the Taiwan 100 MB chunk well below the 4.4 GiB budget — **without** raising
`max_memory` and without changing output semantics.

Non-goals: changing categorisation/confidence rules, changing the output schema, changing chunking.

## 3. Design

Read `properties` directly as `MAP(VARCHAR, VARCHAR)` in the JSON reader instead of `JSON`.
DuckDB parses each record once (yyjson) and every downstream access becomes a map lookup.

Verified in the CI image (DuckDB 1.5.5):

```sql
SELECT properties['@id'], properties['missing'], map_keys(properties)
FROM read_json('x.jsonl', format='newline_delimited',
               columns={'geometry': 'JSON', 'properties': 'MAP(VARCHAR, VARCHAR)'});
-- @id=123 -> '123' (numbers become VARCHAR), missing key -> NULL,
-- keys with ':' and '"' preserved, CJK preserved
```

### 3.1 Mechanical rewrite rules

| Before                                                    | After                                    |
|-----------------------------------------------------------|------------------------------------------|
| `json_extract_string(props, '$.amenity')`                 | `props['amenity']`                       |
| `json_extract_string(props, '$."disused:amenity"')`       | `props['disused:amenity']`               |
| `json_extract_string(props, '$."' \|\| k \|\| '"')` (incl. escaped variant in `osm_raw_tags`) | `props[k]` |
| `json_keys(props)`                                        | `map_keys(props)`                        |
| `osm_raw_tags(props)` (3x key scan + per-key parse)       | `map_from_entries([e for e in map_entries(props) if NOT starts_with(e.key, '@')])`, `NULL` if empty |
| `osm_names_common` / `osm_brand_common` (2x key scan)     | single list comprehension over `map_entries(props)` |
| `properties` column type in `06_places_transform.sql`     | unchanged name, type becomes `MAP(VARCHAR, VARCHAR)` |

Macro signatures stay identical (`props`), so call sites in `03_categorization.sql` etc. do not change.

### 3.2 Files

| File | Change |
|------|--------|
| `scripts/export_pois.sql` | FIFO view `osm_json_src`: `columns={'geometry': 'JSON', 'properties': 'MAP(VARCHAR, VARCHAR)'}` |
| `scripts/entrypoint.py` | both `read_json` calls (bootstrap empty relation + per-chunk) use the MAP column type |
| `scripts/sql/02_macros.sql` | rewrite per 3.1 (151 calls, 5 `json_keys`) |
| `scripts/sql/04_confidence.sql` | rewrite per 3.1 (36 calls, 4 `json_keys`) |
| `scripts/sql/06_places_transform.sql` | rewrite per 3.1 (64 calls) |
| `tests/test_unit.sql` | JSON literals (`'{...}'::JSON`) -> `'{...}'::JSON::MAP(VARCHAR, VARCHAR)` (72 occurrences); prefer one helper macro `tags_of(json_text)` |
| `docs/duckdb_gotchas.md`, `AGENTS.md` | document the invariant "never `json_extract_*` on properties; properties is a parsed MAP" |

### 3.3 Semantic edge cases to verify

- Missing key -> `NULL` (same as `json_extract_string`).
- Numeric attributes (`@id`, `@version`, `@timestamp`) arrive as VARCHAR; existing `TRY_CAST`s keep working.
- Empty-string values: `!= ''` filters unchanged.
- JSON `null` values / nested objects: osmium never emits them for tags; assert in a unit test.
- Duplicate keys: impossible in OSM tags; MAP cast would reject — acceptable (transparent failure).
- Map lookup is a linear scan over the row's keys — still O(tags) vs O(document) per access.
  If profiling shows it matters, Phase 3 option: `STRUCT` of the 78 fixed keys + `MAP` for the
  dynamic `name:*` / `brand:*` / `payment:*` / raw tags.

## 4. Phases

### Phase 0 — Baseline & confirm "why Taiwan" (read-only)
1. From build 454 CI logs, extract max `rows staged` per `[CHUNK n]` for US, DE, FR and compare with
   Taiwan's 168k.
2. Record baseline outputs: Taiwan with 10 MB chunks (current code), Monaco/Luxembourg default.
3. Record peak RSS per 100 MB chunk with the probe script (`probe.py full`, `max_memory=10GB`).

### Phase 1 — Reader + macros rewrite
1. Switch reader column type (3.2, `export_pois.sql` + `entrypoint.py`).
2. Rewrite `02_macros.sql`, `04_confidence.sql`, `06_places_transform.sql` per 3.1.
3. `grep -n "json_extract\|json_keys" scripts/sql` must return no hits on `props`/`properties`.

### Phase 2 — Tests
1. Adapt `tests/test_unit.sql` literals; add unit tests for 3.3 edge cases
   (numeric attributes, `:` and `"` in keys, CJK values, empty raw-tag map -> `NULL`).
2. Add a regression probe: synthetic chunk of N tag-rich points, assert peak RSS budget
   (extend `tests/test_chunked_streaming.sh`).

### Phase 3 — Validation
1. `tests/run_unit_tests.sh`, `tests/test_conversion.sh`, `tests/test_streaming_plan.sh`,
   `tests/test_chunked_streaming.sh` green.
2. **Output equivalence** Taiwan (new code, 100 MB chunks) vs baseline (old code, 10 MB chunks):
   identical row count and identical `id`, `categories`, `names`, `brand`, `tags`, `confidence`,
   `addresses`, `parent_osm_id` (DuckDB `EXCEPT` both directions = 0 rows).
3. Same equivalence for Monaco/Luxembourg.
4. Peak RSS of Taiwan 100 MB chunk: target **< 1.5 GB** (from 4.2 GB).
5. CI run of the full world matrix; compare per-job runtime vs build 454 (expected faster).

### Phase 4 — Optional follow-ups
- Evaluate `is_poi_candidate` double evaluation (`base_json` + `valid_geoms`): compute once as a column.
- STRUCT + MAP hybrid (3.3) if map lookups show up in the profile.
- Row-bounded chunking as an additional guard (secondary; not needed if Phase 3.4 holds).

## 5. Risks

| Risk | Mitigation |
|------|------------|
| Silent semantic drift in ~250 rewritten expressions | Phase 3.2 full-output `EXCEPT` diff on Taiwan + small country |
| MAP cast fails on an unexpected value type in some region | transparent failure (job fails loudly); add Phase 2 unit test; world CI run |
| Unit tests rely on JSON-typed literals | single helper macro for test fixtures |
| CLI/FIFO path diverges from Python path | both use the same `osm_json_src` column spec; `test_streaming_plan.sh` covers the FIFO path |

## 6. Reproduction commands

```bash
# inside ghcr.io/krizleebear/osm2parquet:v1.1.0, repo mounted at /repo, data at /work
./scripts/entrypoint.sh /work/TW_taiwan.pois.pbf /work/out/TW_taiwan.places.parquet TW        # OOM today
OSM_POIS_CHUNK_BYTES=10485760 ./scripts/entrypoint.sh /work/TW_taiwan.pois.pbf /work/out/TW_taiwan.places.parquet TW  # passes (baseline)
```

## 7. Implementation Results

All phases below were executed locally against the real data; Phase 0 (CI log extraction) was
deferred and replaced by a full local reproduction of the CI failure.

| Check | Baseline (JSON reader) | New (MAP reader) |
|---|---|---|
| Taiwan OOM reproduction (28.9 MB filtered PBF, 4.4 GiB cap) | `[FATAL] Out of Memory Error: failed to allocate data of size 16.0 MiB (4.4 GiB/4.4 GiB used)`, no `[CHUNK 1]` logged | passes, no OOM |
| Taiwan wall time | 44 s (10 MB chunks) | **12 s** (100 MB chunks) |
| Taiwan output equivalence | 254,730 POIs | 254,730 POIs, `EXCEPT ALL` 0/0 both directions, md5 `2e07b223b3e95e9b816646bd1ee745a2` |
| DE touchstone (487 MB PBF) | 360 s / 3,186,335 POIs / ~3.91 GB peak | **169 s** / 3,186,335 POIs, `EXCEPT ALL` 0/0 (all columns incl. geometry) |
| Tag-rich 100 MB synthetic chunk | 2638 MB peak RSS, 154.9 s | **740 MB** peak RSS, 2.6 s (budget 1536 MB) |
| `run_unit_tests.sh` / `test_conversion.sh` | — | EXIT=0 (incl. Check 4.5 parity, chunked bit-identity, KV_METADATA) |

Deliverables: `tests/test_memory_budget.sh` (RSS regression guard, wired into `test_conversion.sh`),
Check 4.5 MAP↔`json_extract_string` parity fixtures in `tests/test_unit.sql`, and the invariant
documentation in `AGENTS.md` §3.15 / `docs/duckdb_gotchas.md` §2.3.
