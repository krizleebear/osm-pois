# Handoff — US East OOM Investigation & Chunked-Streaming/Python Pivot (2026-10-06)

This document is the handoff/state snapshot for the US East `us_east` OOM work.
It survives devcontainer restarts (it lives in the mounted repo `/app`). The
ephemeral workspace `/tmp/opencode/` does **not** survive a container restart.

> **Revision 2026-10-07:** the python-library path for the pivot was approved (see
> §4.2); the stdlib-only option was dropped after the `fsspec` probe. Update notes
> are marked `2026-10-07`.
>
> **Revision 2026-10-07 (evening) — IMPLEMENTED & VERIFIED:** Root Cause #2 is now
> fixed in the working tree (untested-uncommitted): `scripts/entrypoint.py` (chunked
> BytesIO driver), SQL modular refactor (`scripts/sql/06_places_transform.sql`),
> `tests/test_chunked_streaming.sh`, docs, and `entrypoint.sh` wiring. All local tests
> green; DE acceptance run measured 3,185,955 POIs in 30 chunks at ~2.9 GB peak RSS
> (bounded, previously 4.5–4.7 GB FIFO/linear). See §7/§10 for details.

---

## 1. Current Git State

- Branch: `main`
- HEAD: `61b529c` — `fix(pipeline): pin join build side to restore streaming on large extracts`
- **Uncommitted work in working tree (MUST be reviewed/committed or stashed):**
  - `M .devcontainer/Dockerfile` — Python 3 + `duckdb==1.5.5` + `fsspec` PyPI.
  - `M azure-pipelines.yml` — image bumped to `ghcr.io/krizleebear/osm2parquet:v1.1.0`
    (contains Python duckdb + fsspec; user-provided).
  - `M scripts/entrypoint.sh` — STAGE 2 delegates to Python driver (chunked ingest,
    no FIFO/sed/duckdb-CLI); `set -e`-safe wait wrapper for clean failure messages.
  - `A scripts/entrypoint.py` — chunked streaming driver (DuckDB Python API + fsspec).
  - `M scripts/export_pois.sql` — `osm_json_src` indirection view + `SET VARIABLE
    country_code`; COPY now `COPY (SELECT * FROM places_export WHERE 1=1 __SPATIAL_FILTER__)`.
  - `A scripts/sql/06_places_transform.sql` — `places_export` transform view
    (single source of truth), read by both CLI/FIFO and Python paths.
  - `A tests/test_chunked_streaming.sh` (+ hook in `test_conversion.sh`) — md5
    bit-identity: 10 tiny chunks == single chunk, KV_METADATA intact.
  - `M docs/*` — `docs/duckdb_gotchas.md` (new §5 Python-driver gotchas),
    `docs/azure_pipelines.md` (new §3.6), `README.md`, `AGENTS.md`.

Do **not** run `git reset --hard` or `git clean`; all of the above is intentional.

---

## 2. Problem Being Solved

`us_east` (US East extract) hits DuckDB OOM in CI:

```
Out of Memory Error: failed to allocate data of size 8.0 MiB (4.4 GiB/4.4 GiB used)
```

- `max_memory='4800MB'` is calibrated; host OOM-killer fires above ~5200MB, so
  raising `max_memory` is NOT a valid fix.
- Two independent root causes were found. Cause #1 is fixed (committed). Cause #2
  is diagnosed and a fix strategy is proven in a PoC but **not yet implemented**.

### Root Cause #1 (FIXED, commit `61b529c`)
FIFO has no file size → DuckDB estimates `read_json()` stream ≈ 42 rows →
`build_side_probe_side` optimizer swaps the LEFT JOIN, making the POI stream
(millions of rows) the hash-build side → massive memory blowup.

Fix: `SET disabled_optimizers = 'build_side_probe_side';` in
`scripts/export_pois.sql` (line ~169). Regression tests added:
- `tests/run_unit_tests.sh` (asserts plan)
- `tests/test_streaming_plan.sh` (new; verifies `read_json()` is probe-side only)

### Root Cause #2 (DIAGNOSED, fix strategy proven, NOT implemented)
DuckDB JSON reader buffers the ENTIRE pipe input in RAM. Source:
`extension/json/json_reader.cpp`, `JSONFileHandle::Read()`:

```cpp
if (IsPipe() && temp_read_size != 0) {
    cached_buffers.emplace_back(allocator.Allocate(temp_read_size));
    memcpy(...);
}
```

This is unconditional, never evicted, scoped per `read_json()` call lifetime.
Verified identical in v1.5.5 and master. **No setting disables it.** Same design
flaw exists for CSV pipes (DuckDB issue #25165; PR #16480 fixed only correctness,
not memory). Relevant upstream refs: PR #1957 (pipe/stream FS), issue #25165.

Implication: a 2.3 GB piped JSONL → ~2.3 GB held in RAM by the reader alone.
File mode (seekable) has constant memory; only pipes are affected.

---

## 3. What WAS Already Proved (empirical, local PoC)

Input: `/tmp/opencode/full.jsonl` — 2.3 GB, 5,110,761 lines (extracted from
`us_east.pois.pbf`, DuckDB CLI `v1.5.5`, `max_memory='4800MB'` unless noted).

| Test | Peak RSS | Exit | Note |
|---|---|---|---|
| Reader count(), regular file | 0.01 GB | 0 | constant memory |
| Reader count(), single FIFO pipe | 2.32 GB | OOM @1.2GB cap | = input size (cause #2) |
| Full pipeline, file mode + fix #1 | 2.98 GB | 0 (2,213,751 rows) | works |
| Full pipeline, FIFO + fix #1 | OOM | 1 | pipe cache on top of 2.98GB |
| Full pipeline, `full.jsonl.gz` (571MB) file | 2.66 GB | 0 (2,213,751 rows) | fallback proven |
| Full pipeline, gzip-over-FIFO | — | 1 | `Malformed JSON at byte 1` (compressed pipe unsupported) |
| Full pipeline, ONE 100MB chunk via FIFO | 3.90 GB | 0 (74,753 rows / 9.4s) | chunking works |

Production output baseline (file mode, after fix #1): **2,213,751 rows**.

---

## 4. The Chosen Direction — PIVOT to Python (user-approved container change)

⚠️ **2026-10-07 update:** the stdlib-only restriction was initially proposed for the
driver, but **`fsspec` is a hard requirement** for reading `io.BytesIO` objects via
`read_json(...)` in the Python API (probe error: `required module 'fsspec' is not
installed`). The user has therefore **approved using Python libraries** after all
(`duckdb==1.5.5` PyPI + `fsspec`). See §4.2 below.

The Bash/awk/FIFO/ACK approach (see §5) proved the chunking concept but is
fragile (≈150 lines of orchestration for producer/consumer rendezvous). The user
approved pivoting to a Python driver:

- The whole FIFO/ACK choreography collapses to a ~60-line Python loop using the
  **`duckdb` PyPI package**.
- Python feeds each ~100MB line-aligned chunk to `read_json()` as an in-memory
  **seekable BytesIO object** — NOT a pipe — so the `IsPipe()` cache branch is
  never entered (hypothesis; see §7 spike).
- One DuckDB process, one session, `N` chunks, **one** final Parquet, no merge.
- Python is tier-2 in the AGENTS.md language hierarchy (`DuckDB SQL > Python 3 > Bash`),
  and isolated from pipeline-invariant #8 (no runtime `apt-get install`; image is
  pre-built).

### Why Python is genuinely better here
- Native subprocess mgmt (`osmium export` as child, live stdout read, byte-aware
  line-aligned chunk buffer, bounded memory).
- True exception handling + guaranteed cleanup vs. shell exit-code correctness.
- Kills: `mkfifo`, awk `close(fifo)` rendezvous races, ACK manifest files, poll
  loops, per-chunk parquet merges. Single output file.

### 4.2 Approved Dependencies (2026-10-07)

The user signed off on the python-library path for the driver. The minimal,
version-matched dependency set is:

| Package | Version | Why |
|---|---|---|
| `duckdb` (PyPI) | `1.5.5` (must match CLI) | in-process engine, `read_json(BytesIO)` |
| `fsspec` | latest | prerequisite for file-like input objects to `read_json` |

`fsspec` is tiny and pure-Python, so it adds no meaningful image weight. Everything
else stays stdlib (subprocess, io, signal, tempfile, os).

**Consequence for the production image** (`ghcr.io/krizleebear/osm2parquet:v1.0.10`,
built from `krizleebear/osm-addresses/docker/osm2parquet/Dockerfile`): that image
currently ships only bare `python3` (Debian bookworm) — **no pip-installed duckdb,
no fsspec**. To run the Python driver in CI, the osm2parquet image must be
re-published with `duckdb==1.5.5` + `fsspec` (user has approved; §7.1, §8, and the
osm-addresses Dockerfile must be updated accordingly). This is tracked as part of
the immediate next steps.

---

## 5. Proved Concept (RECORD of the Bash/awk PoC — keep as reference/fallback)

The chunked-streaming idea was fully validated before the pivot:

- **Chunk boundary MUST be line-aligned** — never hard-split at byte N (JSONL
  records corrupt). Producer accumulates bytes and closes only after a complete
  record; chunks overshoot by ≤ one record (max observed: 112 MB).
- **`close(fifo)`/reopen is NOT a handshake.** Without an explicit ACK the
  producer outruns the reader and fuses multiple chunks into one stream (→
  reader cache grows again). Verified failure mode.
- **ACK lock-step works deterministically:** producer closes FIFO (→ EOF to
  `read_json()`), then blocks until a `ack_N` file appears; consumer runs one
  `read_json()` per chunk, then touches `ack_N`. 24/24 chunks → total
  5,110,761 rows exact. Peak ~264 MB/chunk (count), 3.90 GB/chunk (full export).
- awk-based splitter = 0.04 s/chunk vs Bash `while read` = 2.7 s (37 MB/s, too
  slow). awk documented here for the record even though Python supersedes it.

PoC scripts (lost on restart — regenerable from this doc):
`/tmp/opencode/poc/{ack_test,awk_ack_test,run_chunk_test,run_chunk_full}.sh`.

---

## 6. Decision & Trade-offs Recorded

- **gz temp file** (571 MB disk vs 2.3 GB JSONL, peak 2.66 GB, 1-pass PBF) is a
  proven fallback but violates invariant #11 ("zero intermediate disk I/O" via
  named pipes). User prefers chunked streaming/Python over this.
- `COPY ... (APPEND true)` for Parquet is **silently ignored in DuckDB v1.5.5**
  (verified: 5 rows stay 5 rows). So "insert into the first parquet" via COPY is
  not possible; accumulation happens inside one session/table instead.
- Chunked design keeps the PBF 1-pass invariant (single `osmium export`), which
  is the spirit of invariant #11.

---

## 7. Immediate Next Steps (in priority order)

1. **Build & test the extended devcontainer:**
   `docker compose -f docker-compose.dev.yml build` (or reopen in VSCode dev
   container). This cannot be done on the current host (no Docker, no root).
   Verify: `python3 --version`, `python3 -c "import duckdb; print(duckdb.__version__)"`
   (expect `1.5.5`), and `python3 -c "import duckdb; duckdb.sql('LOAD spatial;')"`
   works offline (extensions copied to `/home/ubuntu/.duckdb`).

2. **BytesIO spike (de-risks the pivot):**
   Feed `full.jsonl` through, say, a handful of `read_json(<BytesIO chunk>)`
   calls with `max_memory='1200MB'` hard cap and confirm peak RSS stays near the
   chunk size (NOT full input). If the seekable BytesIO still triggers the pipe
   cache, fall back to Python-managed FIFO (equivalent ACK logic, but in Python)
   — same memory model, already proven in §5.
   - **Spike prerequisite discovered (2026-10-07):** `read_json()` on a Python
     `io.BytesIO` requires the **`fsspec`** module (`fsspec` is not bundled with
     duckdb's Python wheel). It is now an approved dependency (§4.2).
   - **Spike status (2026-10-06/07):** the spike could NOT be fully executed on
     the current host in its original form because the PoC input
     (`/tmp/opencode/full.jsonl`, 2.3 GB) was lost on container restart. The
     PBF survives in the repo (`US_us.pois.pbf`, 897 MB) and `full.jsonl` can be
     regenerated per §9.

3. **Design `scripts/entrypoint.py`** (or a thin Python wrapper driving the
   existing `export_pois.sql`), wiring: subprocess osmium → line-aligned ~100MB
   chunk buffer → per-chunk `read_json(BytesIO)` → accumulate → single
   final Parquet. Keep the fixed `build_side_probe_side` disabled-optimizer.

4. **Test-suite expansion (AGENTS.md mandatory):** extend
   `tests/test_unit.sql`/`test_conversion.sh` for chunked ingest (5,110,761
   total row integrity equivalent, per-chunk memory cap assertion if feasible).

5. **Docs after the design is chosen:** update `docs/azure_pipelines.md` §3.1
   (currently claims the FIFO single-pass is the memory fix — now incomplete
   after cause #2), add the JSON-reader pipe-cache gotcha to
   `docs/duckdb_gotchas.md`, and amend AGENTS.md invariant #11 if the final
   design no longer uses a named pipe for POI ingest.

---

## 8. Environment Facts (spike bootstrap on a fresh container)

On this host there is **no** `python3`, **no** `docker`, **no** root/sudo.
`apt-get install` fails without root. `uv` static-binary install also failed
(home-dir owned by root, and the binary runs under qemu on this host). Do not
waste time redoing these; the fix is the devcontainer rebuild from §7.1.

> **2026-10-07 note:** the current working container now DOES have `python3`
> (3.14.4) + `duckdb==1.5.5` (PyPI) + offline `LOAD spatial`, i.e. the §7.1
> devcontainer is effectively provisioned here already. Docker is still absent
> on this host.

The devcontainer change currently in the tree (`.devcontainer/Dockerfile`):
- apt adds: `python3 python3-pip python3-venv python3-dev`
- new step 2b: `pip install --break-system-packages duckdb==1.5.5` (PEP-668
  required on Ubuntu 26.04) + `INSTALL spatial` via Python
- moved the `/root/.duckdb` extension snapshot AFTER the Python install so both
  CLI and Python extensions are copied to `/home/ubuntu/.duckdb` (offline
  `LOAD spatial` for both).

Do NOT merge pip into the prod `osm2parquet` image without the user signing off
— that image is the CI container and is governed by invariant #8 + §4.5.

---

## 9. Useful Commands (recreate PoC inputs if needed)

```bash
# regenerate full.jsonl from the PBF (FIFO not needed for file extraction):
osmium export us_east.pois.pbf --geometry-types=point,polygon \
  --attributes=type,id,version,timestamp --output-format=geojsonseq \
  | tr -d '\036' > /tmp/opencode/full.jsonl
gzip -1 -c /tmp/opencode/full.jsonl > /tmp/opencode/full.jsonl.gz  # 571MB fallback

# line-aligned chunk splitter (proof, per §5):
awk '{ print > sprintf("/tmp/opencode/poc/chunk_%04d.ndjson", f); bytes+=length($0)+1;
       if (bytes>=104857600){ close(...); f++; bytes=0 } }'
```

Primary repro files on disk now (LOST on restart, but PBF survives in repo/tests):
- `/tmp/opencode/full.jsonl` (2.3 GB, 5,110,761 rows)
- `/tmp/opencode/full.jsonl.gz` (571 MB, 9.6 s to compress)
- `/tmp/opencode/us_east.pois.pbf` (359 MB)
- `/tmp/opencode/poc/*` (PoC scripts, chunky parquet variants, memory CSVs)

> **2026-10-07 note:** `/tmp/opencode/*` was wiped on restart (as predicted).
> Regenerate per the commands above. The repo now contains `US_us.pois.pbf`
> (897 MB, the full-US input from which `us_east` was previously split via
> `osmium extract -b -85,15,-65,72`) and `DE_germany.pois.pbf` (487 MB), plus
> the 359 MB `us_east` partition can be re-derived as needed.

---

## 10. Implementation & Verification Record (2026-10-07, evening)

### 10.1. What was built
- `scripts/entrypoint.py`: one DuckDB connection over a disk-backed `stage.duckdb`;
  spawns `osmium export` and chunks its stdout at line boundaries (~`OSM_POIS_CHUNK_BYTES`
  default 100 MB), strips `0x1e` in-process, registers each chunk via
  `con.register('osm_json_src', con.read_json(io.BytesIO(chunk), ...))`, re-binds the
  shared `places_export` view from `06_places_transform.sql` per chunk (eager schema
  binding requires it), `INSERT INTO stage` per chunk, then a **single** final
  `COPY ... KV_METADATA` (provenance block parsed verbatim from `export_pois.sql`).
- `scripts/sql/06_places_transform.sql`: the transform SELECT extracted from the old
  inline `COPY (...)`, wrapped in `CREATE OR REPLACE TEMP VIEW places_export`.
  `country_code` moves to `getvariable('country_code')` (`SET VARIABLE` in
  `export_pois.sql`), the `__SPATIAL_FILTER__` WHERE moves to the COPY consumer so the
  `sed` token-injection (CLI path + tests) and the driver substitution stay in one file.
- `scripts/export_pois.sql`: `osm_json_src` indirection view (CLI/FIFO) + `SET VARIABLE
  country_code`; `COPY (SELECT * FROM places_export WHERE 1=1 __SPATIAL_FILTER__)`.
- `tests/test_chunked_streaming.sh`: forces ~10 tiny chunks (200 KB) via the driver and
  asserts bit-identity (md5) with a single-chunk run + KV_METADATA keys; wired into
  `test_conversion.sh`.
- Docs updated: `docs/duckdb_gotchas.md` §5 (BytesIO/fsspec, register-vs-view clash,
  eager view binding, `INSERT ... SELECT` → `(affected,)`, persistent-DB staging spill,
  multi-statement `execute()`), `docs/azure_pipelines.md` §3.6, `README.md`, `AGENTS.md`.

### 10.2. Verification results (local, dev shell — not the container image)
| Check | Result |
|---|---|
| `./tests/run_unit_tests.sh` | PASS (unit + taxonomy linter + streaming physplan + pipeline + viewer guards) |
| `tests/test_streaming_plan.sh` | PASS (README_JSON probe-side only, 2 hash joins) |
| `tests/test_conversion.sh` (Monaco) | PASS — 1,182 POIs, all schema/address/relation/meta assertions |
| chunked(10) vs single-chunk output | **bit-identical** — md5 `70ee6e4be7609417628af7cd88ed32aa` |
| CLI/FIFO path (reference) | 1,182 POIs, same md5 `70ee6e4b...` (parity) |
| **DE acceptance (487 MB PBF)** | 3,185,955 POIs, 30 chunks, ~**2.9 GB peak RSS**, 360 s, 0 duplicates |

The DE number directly matches the touchstone (8.3M features → 3.18M POIs) and confirms
the fix: peak RSS is now chunk-bounded (~2.9 GB) instead of growing linearly toward the
4.4-4.7 GB OOM cliff.

### 10.3. Remaining / optional
- [ ] Commit the working tree (conventional commits; see §1 for the file list) after a
      final review + `git diff origin/main`.
- [ ] Confirm `us_east` on Azure CI with image `v1.1.0` (local host cannot run the
      container; DE acceptance above is the local proxy).
- [ ] Optional: reduce staging DB WAL by running the final COPY and checking the
      `.duckdb` file size vs the parquet output.
- [ ] Optional: `tests/test_chunked_streaming.sh` could reuse `OSM_POIS_CHUNK_BYTES`
      env passthrough to reduce two hard-coded runs.