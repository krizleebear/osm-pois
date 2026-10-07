# DuckDB, Arrow & Osmium CLI / Execution Gotchas

This document details critical engine-level gotchas, CLI flags, serialization invariants, and troubleshooting patterns encountered in the `osm-pois` pipeline.

---

## 1. CLI Execution Flags & Terminal Dynamics

### 1.1. Terminal Background Color Probe Timeout (> 5s)
* **Symptom**: DuckDB hangs for 5 seconds on startup in non-interactive terminals, emitting:
  ```text
  Timeout trying to read terminal background color (> 5s elapsed).
  Disable terminal background color detection by using duckdb -dark-mode or duckdb -light-mode.
  ```
* **Rule**: Always pass `-dark-mode -no-stdin` when invoking `duckdb` from bash scripts or automated test runners:
  ```bash
  duckdb -dark-mode -no-stdin -c "..."
  ```
  Alternatively, configure `~/.duckdbrc` with `.highlight_mode dark` (pre-configured in `.devcontainer/Dockerfile`), which loads before the terminal probe during initialization and completely bypasses the 5-second OSC 11 timeout.


### 1.2. Input Redirection Pitfall vs `.read`
* **Symptom**: Piping SQL via stdin (`duckdb -no-stdin < script.sql`) exits immediately with code 0 without executing any queries.
* **Explanation**: `-no-stdin` disables standard input. Piping closes stdin immediately.
* **Rule**: Always invoke SQL scripts via the CLI dot-command:
  ```bash
  duckdb -dark-mode -no-stdin -c ".read script.sql"
  ```

### 1.3. `.read` is a CLI Dot-Command (NOT SQL)
* **Symptom**: Chaining `.read` with SQL statements inside a single `-c` flag (e.g. `duckdb -c "SET x=1; .read file.sql"`) fails with `Parser Error: syntax error at or near '.'`.
* **Rule**: Pass separate `-c` flags for each step, or place all commands inside the `.sql` file:
  ```bash
  duckdb -dark-mode -no-stdin \
    -c "SET VARIABLE repo_root = '/app';" \
    -c ".read scripts/sql/01_taxonomy.sql"
  ```

### 1.4. Docker Container Git `safe.directory`
* **Symptom**: Because dev containers mount `~/.gitconfig` read-only (`:ro`), running `git config --global` fails with `fatal: resource busy`.
* **Rule**: Configure `ENV GIT_CONFIG_PARAMETERS="'safe.directory=/app'"` in the container environment or Dockerfile to permit git operations across mounted repository volumes.

---

## 2. DuckDB SQL & Script Template Invariants

### 2.1. Template Substitution on `COPY TO` Paths
* **Invariant**: DuckDB `COPY ... TO 'path'` requires a compile-time string literal. Dynamic expressions or `getvariable()` calls inside `COPY TO` are rejected by DuckDB's parser.
* **Rule**: Use lightweight token substitution (`sed`) on SQL templates before piping into `duckdb`:
  ```bash
  sed -e "s|__INPUT_JSONL__|${FIFO_PATH}|g" \
      -e "s|__OUTPUT_PARQUET__|${OUTPUT_FILE}|g" \
      scripts/export_pois.sql | duckdb -dark-mode -no-stdin
  ```

### 2.2. JSONPath & String Quoting
* **Scope**: Only applies to genuine JSONPath lookups (e.g. the `EXPLAIN` plan JSON in `tests/test_streaming_plan.sh`). Never build JSONPath strings for OSM `properties` — see §2.3.
* **Invariant**: In DuckDB SQL, double quotes within single-quoted string literals must **NOT** be escaped with backslashes.
  * Correct: `'$."' || k || '"'`
  * Incorrect: `'$.\"' || k || '\"'`
* **Explanation**: DuckDB does not treat backslash as an escape character in standard string literals. Including `\` causes DuckDB to pass a literal backslash into `json_extract_string`, which silently breaks JSONPath key lookup and returns `NULL`.

### 2.3. Single-Pass Properties Parsing (`properties` is a MAP, never JSON)
* **Invariant**: The GeoJSON `properties` column is declared as `MAP(VARCHAR, VARCHAR)` (never `JSON`) and every tag access is a map lookup:
  * Correct: `props['amenity']`, `map_keys(props)`, `[e for e in map_entries(props) if NOT starts_with(e.key, '@')]`
  * Incorrect: `json_extract_string(props, '$.amenity')`, `json_keys(props)`
* **Why**: `json_extract_*` re-parses the full JSON document on *every* call. The transform performs ~230 static lookups plus key-iterating macros (`osm_name_keys`, `osm_raw_tags`, payment/lifecycle scans), so per-row cost becomes `#tags x document size`. On a single 100 MB Taiwan chunk this pushed the driver past the 4.4 GiB `max_memory` cap before `[CHUNK 1]` could ever be logged:
  ```
  [FATAL] Out of Memory Error: failed to allocate data of size 16.0 MiB (4.4 GiB/4.4 GiB used)
  ```
* **Measured** (real Taiwan extract, 28.9 MB filtered PBF): legacy JSON reader OOM-reproduced; MAP reader completed with a **12 s** vs **44 s** run and byte-identical output (254,730 POIs, `EXCEPT ALL` = 0/0, md5 `2e07b223b3e95e9b816646bd1ee745a2`). DE touchstone: 3,186,335 POIs equivalent both ways, 360 s → 169 s.
* **Type semantics** (identical to `json_extract_string`): missing key → `NULL`; JSON numbers/booleans → `VARCHAR` (`'21911886'`, `'true'`); JSON `null` → `NULL`; nested object → its JSON text. Keys may contain `:`, `"` and CJK without quoting gymnastics: `props['disused:amenity']`, `props['fixme:"note"']`.
* **Where the type must match**: `scripts/export_pois.sql` (FIFO view) and both `read_json` `columns=` sites in `scripts/entrypoint.py` — the transform view is bound once against `osm_json_src`, so bootstrap and per-chunk schemas must be identical or `CREATE VIEW` fails with an UnknownError.
* **Guarded by**: `tests/test_memory_budget.sh` (peak-RSS budget on a tag-rich chunk; fails on the legacy reader: 2638 MB vs 726 MB) and `tests/test_unit.sql` Check 4.5 (MAP ↔ `json_extract_string` parity).

---

## 3. Arrow IPC & WebAssembly Serialization

### 3.1. KV Metadata BLOB Keys
* **Invariant**: In DuckDB, `parquet_kv_metadata()` returns `key` and `value` as `BLOB`.
* **Front-End / Wasm Pitfall**: When consumed through DuckDB-Wasm or Apache Arrow IPC in JavaScript, uncast BLOB keys collapse into `"[object Uint8Array]"`, causing silent key collisions and wiping out metadata.
* **Rule**: Always explicitly cast BLOB fields:
  ```sql
  SELECT CAST(key AS VARCHAR) AS k, CAST(value AS VARCHAR) AS v FROM parquet_kv_metadata('places.parquet');
  ```

### 3.2. Confidence & Ratio Decimal vs Double Scaling
* **Invariant**: DuckDB `round(..., 2)` produces `DECIMAL(11,2)`.
* **Arrow IPC Pitfall**: In Apache Arrow IPC, decimals are serialized as raw unscaled integers (e.g. `99` instead of `0.99`), causing a 100x magnification error (`9900%`) in web viewers.
* **Rule**: All normalized ratio and confidence macro outputs must explicitly cast to `::DOUBLE` matching Overture Places schema:
  ```sql
  round(..., 2)::DOUBLE
  ```
  Frontend consumers must defensively clamp and scale values (`confVal > 1.0 ? confVal / 100.0 : confVal`).

---

## 4. Remote S3 & HTTP Streaming via `httpfs`

To audit remote releases, benchmark category distributions, or compare against official Overture data without downloading multi-gigabyte files, stream directly via DuckDB:

```sql
-- 1. Load extension
INSTALL httpfs;
LOAD httpfs;

-- 2. Configure anonymous access to Overture public S3 bucket
CREATE SECRET overture (TYPE S3, KEY_ID '', SECRET '', REGION 'us-west-2');

-- 3. Leverage bbox metadata / part files for high-throughput spatial pruning:
SELECT count(*), categories.primary
FROM read_parquet('s3://overturemaps-us-west-2/release/2026-08-19.0/theme=places/type=place/*')
WHERE bbox.xmin >= 5.86 AND bbox.xmax <= 15.04
  AND bbox.ymin >= 47.27 AND bbox.ymax <= 55.06
  AND addresses[1].country = 'DE'
GROUP BY ALL;
```

---

## 5. DuckDB Python Streaming Driver (`scripts/entrypoint.py`)

The chunked driver replaced the FIFO/awk orchestration in `scripts/entrypoint.sh` to bypass the JSON reader's named-pipe cache OOM (Root Cause #2 of the US-east SIGKILL). See `AGENTS.md` and the HANDOFF doc for the full rationale. Hard-won APIs & pitfalls:

### 5.1. `read_json(io.BytesIO(...))` Requires `fsspec`
* `duckdb.read_json(io.BytesIO(b'...'), format='newline_delimited', ..., columns={...})` works, but **only if the `fsspec` package is importable**. Without it DuckDB raises:
  ```
  Invalid Input Error: ... required module 'fsspec' is not installed
  ```
* On Ubuntu 24.04+/26.04 (PEP 668) install with `python3 -m pip install --break-system-packages duckdb==1.5.5 fsspec`. The image pins both (`ghcr.io/krizleebear/osm2parquet:v1.1.0`).
* Passing a `BytesIO` object as a SQL parameter (e.g. `con.execute("SELECT * FROM read_json(?, ...)", [io.BytesIO(...)])`) throws `NotImplementedException` — always build the relation via `con.read_json(...)` and register it.

### 5.2. `register()` Name Collisions with Views
* `con.register('name', rel)` fails with `CatalogException: View with name "name" already exists` if a temp view (or table) with the same name exists in the session catalog.
* The driver therefore **strips the FIFO `osm_json_src` view** from the shared `scripts/export_pois.sql` init script and instead registers each BytesIO chunk under that exact name (mutually exclusive activation paths).

### 5.3. `CREATE VIEW` Binds its Source Schema Eagerly
* A view whose body reads `FROM osm_json_src` fails to `CREATE` while `osm_json_src` does not exist yet. You cannot define the view "lazily" ahead of the first chunk.
* Driver recipe: register chunk N → `con.execute(<06 transform>)` (`CREATE OR REPLACE TEMP VIEW places_export`) → `INSERT INTO stage SELECT * FROM places_export` → register chunk N+1 → repeat. Re-binding the view per chunk is deterministic and cheap.

### 5.4. `INSERT ... SELECT` Returns `(affected,)`, Not `rowcount`
* `con.execute("INSERT INTO stage SELECT ...").fetchone()` returns a single-row result `(n,)` where `n` is the number of inserted rows (`(0,)` when a filter matched nothing). `cursor.rowcount` stays `-1`. Count correctly with `fetchone()[0]`.
* DuckDB does **not** support data-modifying CTEs: `WITH ins AS (INSERT ... RETURNING id) SELECT count(*) ...` is a parser error.

### 5.5. Bounded Memory: Persistent Database File, not `TEMP`
* A persistent connection (`duckdb.connect('/tmp/.../stage.duckdb')`, NOT `duckdb.connect()` in-memory) allows the **buffer manager to evict staging-table blocks to the `.duckdb` file** under memory pressure. `CREATE TEMP TABLE` deliberately never spills — the accumulation table must be a **persistent** table. Measured: DE (487 MB PBF) → 3,185,955 POIs staged in 30 chunks at ~2.9 GB peak RSS, bounded regardless of total input size.
* `temp_directory` spills *intermediate* operator output (sorts/hashes); it does not spill base table data.

### 5.6. Multi-Statement `con.execute()` Works
* `con.execute(sql_with_many_statements; ; ...)` executes the whole script (including `CREATE MACRO` and `SET VARIABLE ... = (SELECT ...)`), so the driver can bootstrap the entire modular pipeline by expanding the `.read` dot-commands inline (dot-commands themselves are not executable from the Python API).
