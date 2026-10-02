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
* **Invariant**: In DuckDB SQL, double quotes within single-quoted string literals must **NOT** be escaped with backslashes.
  * Correct: `'$."' || k || '"'`
  * Incorrect: `'$.\"' || k || '\"'`
* **Explanation**: DuckDB does not treat backslash as an escape character in standard string literals. Including `\` causes DuckDB to pass a literal backslash into `json_extract_string`, which silently breaks JSONPath key lookup and returns `NULL`.

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
