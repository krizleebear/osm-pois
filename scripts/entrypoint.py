#!/usr/bin/env python3
"""Chunked streaming OSM PBF -> Overture Places GeoParquet driver (DuckDB Python API).

Pivots the legacy FIFO/awk orchestration in entrypoint.sh to a single Python process
in order to sidestep DuckDB's JSON-reader pipe-cache OOM (Root Cause #2 of the US East
SIGKILL): osmium's newline-delimited GeoJSON stream is read from the subprocess stdout
in bounded chunks (~OSM_POIS_CHUNK_BYTES, line-aligned), each chunk is registered as an
in-memory BytesIO relation under the shared view name ``osm_json_src``, the production
transform view (scripts/sql/06_places_transform.sql) runs per chunk, and all rows are
accumulated into a DISK-BACKED staging table inside one DuckDB session.

The final output is written as a SINGLE Overture Places-compatible GeoParquet with the
full KV_METADATA provenance block re-used verbatim from scripts/export_pois.sql. No
intermediate Parquet parts, no merge step, no named pipe, no disk-backed input stream.

Design invariants (see AGENTS.md):
  * One DuckDB connection, one persistent database file for staging
    (buffer manager spills stage blocks to disk -> bounded RSS on 7 GB runners).
  * Zero intermediate disk I/O for the ingest stream (BytesIO only).
  * The categorization / projection SQL is never duplicated: it is the very same
    transform view used by the CLI/FIFO path (single source of truth).
  * KV_METADATA provenance block is parsed out of scripts/export_pois.sql and re-used
    unmodified (tokens substituted), never re-authored.
"""

import argparse
import io
import os
import re
import subprocess
import sys
import time

DEFAULT_CHUNK_BYTES = 104857600  # 100 MB
RS_BYTE = 0x1E  # \036 record separator in GeoJSONSeq streams

OSM_EXPORT_ARGS = (
    "export",
    "--geometry-types=point,polygon",
    "--attributes=type,id,version,timestamp",
    "--output-format=geojsonseq",
    "-x",
    "print_record_separator=false",
)


class OsmExportError(RuntimeError):
    pass


def substitute(sql, tokens):
    for key, value in tokens.items():
        sql = sql.replace(key, value)
    return sql


def expand_module_reads(sql):
    """Inline the modular .read directives (01..05) so the whole init script can be
    executed via the Python driver. The 06 transform view and the trailing COPY are
    handled separately by the caller."""
    pattern = re.compile(r"^\.read\s+(\S+/scripts/sql/0[1-5]_\S+)\s*$", re.M)
    while True:
        match = pattern.search(sql)
        if not match:
            return sql
        path = match.group(1)
        with open(path, encoding="utf-8") as fh:
            module_source = fh.read()
        sql = sql[: match.start()] + module_source + sql[match.end() :]


def strip_top_level_copy(sql):
    """Remove the final CLI/FIFO COPY statement (consumed by the CLI path and the
    streaming-plan regression test); the Python driver re-issues its own COPY."""
    return re.sub(r"^COPY \(.*$", "-- final COPY issued by the Python driver", sql, count=1, flags=re.S | re.M)


def extract_kv_metadata(export_sql):
    match = re.search(r"KV_METADATA \{(.*?)\}\n\);", export_sql, re.S)
    if not match:
        raise RuntimeError(
            "Could not locate the KV_METADATA provenance block in scripts/export_pois.sql"
        )
    return match.group(1)


def iter_jsonl_chunks(proc, chunk_bytes):
    """Yield osmium's stdout in line-aligned chunks.
    Record separators (0x1e) are natively suppressed by osmium (-x print_record_separator=false),
    with a fallback strip if any stray RS byte is encountered."""
    buf = bytearray()
    while True:
        data = proc.stdout.read(1 << 20)
        if not data:
            break
        buf += data
        while len(buf) >= chunk_bytes:
            nl = buf.rfind(b"\n")
            if nl == -1:
                break  # single record larger than the target; keep buffering
            chunk = bytes(buf[: nl + 1])
            del buf[: nl + 1]
            if RS_BYTE in chunk:
                chunk = chunk.replace(bytes([RS_BYTE]), b"")
            yield chunk
    if buf:
        chunk = bytes(buf)
        if RS_BYTE in chunk:
            chunk = chunk.replace(bytes([RS_BYTE]), b"")
        yield chunk


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Input .osm.pbf file")
    parser.add_argument("--output", required=True, help="Output .places.parquet file")
    parser.add_argument("--relations-opl", required=True, help="OPL file with pre-filtered site/parking relations")
    parser.add_argument("--tmp-dir", required=True, help="Scratch directory (spill + staging database)")
    parser.add_argument("--repo-root", required=True, help="Repository root (mappings + docs)")
    parser.add_argument("--country-code", default="", help="ISO country code (addresses + KV_METADATA)")
    parser.add_argument("--spatial-filter", default="", help="Optional AND ... clause appended to the WHERE")
    parser.add_argument("--max-object-size", default="67108864", help="maximum_object_size for the JSON reader (bytes)")
    parser.add_argument("--build-version", default="dev", help="Compiler version for KV_METADATA")
    parser.add_argument("--export-timestamp", default="", help="exported_at ISO 8601 timestamp for KV_METADATA")
    parser.add_argument("--chunk-bytes", default=str(DEFAULT_CHUNK_BYTES), help="Ingest chunk size in bytes")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv) if argv is not None else parse_args(sys.argv[1:])
    repo_root = os.path.abspath(args.repo_root)
    chunk_bytes = int(args.chunk_bytes)
    export_timestamp = args.export_timestamp or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    # ------------------------------------------------------------------
    # 1. Load the shared production SQL (single source of truth)
    # ------------------------------------------------------------------
    export_path = os.path.join(repo_root, "scripts", "export_pois.sql")
    transform_path = os.path.join(repo_root, "scripts", "sql", "06_places_transform.sql")
    with open(export_path, encoding="utf-8") as fh:
        export_sql = fh.read()

    tokens = {
        "__INPUT_RELATIONS_OPL__": args.relations_opl,
        "__COUNTRY_CODE__": args.country_code,
        "__BUILD_VERSION__": args.build_version,
        "__EXPORT_TIMESTAMP__": export_timestamp,
        "__TEMP_DIR__": args.tmp_dir,
        "__SPATIAL_FILTER__": args.spatial_filter,
        "__MAX_OBJECT_SIZE__": args.max_object_size,
        "__INPUT_JSONL__": "__registered_per_chunk__",
        "__OUTPUT_PARQUET__": args.output,
    }

    # Init script: expand modules 01..05, drop the FIFO osm_json_src view (we register
    # BytesIO chunks under that name instead), drop the 06 view (bound per chunk to the
    # currently registered source) and the trailing CLI COPY.
    init_sql = substitute(export_sql, {**tokens, "__REPO_ROOT__": repo_root})
    init_sql = expand_module_reads(init_sql)
    init_sql = re.sub(
        r"CREATE OR REPLACE TEMP VIEW osm_json_src AS.*?;\n",
        "-- osm_json_src is registered per chunk by the driver\n",
        init_sql,
        count=1,
        flags=re.S,
    )
    init_sql = re.sub(
        r"^\.read\s+\S+/scripts/sql/06_places_transform\.sql\s*$",
        "-- places_export is bound per chunk by the driver\n",
        init_sql,
        count=1,
        flags=re.M,
    )
    init_sql = strip_top_level_copy(init_sql)

    with open(transform_path, encoding="utf-8") as fh:
        transform_sql = fh.read()

    kv_metadata = extract_kv_metadata(export_sql)
    kv_metadata = substitute(kv_metadata, tokens)

    # ------------------------------------------------------------------
    # 2. Single DuckDB session over a disk-backed database (staging spills)
    # ------------------------------------------------------------------
    try:
        import duckdb
    except ImportError as exc:
        raise RuntimeError(
            "The duckdb Python package is required for the chunked streaming driver. "
            "Install it (and fsspec, required by read_json(BytesIO)) with: "
            "python3 -m pip install duckdb fsspec"
        ) from exc
    try:
        import fsspec  # noqa: F401 - required by duckdb.read_json(io.BytesIO(...))
    except ImportError as exc:
        raise RuntimeError(
            "The fsspec Python package is required by duckdb.read_json(io.BytesIO(...)) "
            "in the chunked streaming driver. Install it with: python3 -m pip install fsspec"
        ) from exc

    stage_db = os.path.join(args.tmp_dir, "osmpois_stage.duckdb")
    con = duckdb.connect(stage_db)
    try:
        # Register an initial empty schema relation under osm_json_src so transform_sql can be bound once
        empty_chunk = io.BytesIO(b'{"geometry": null, "properties": null}\n')
        init_rel = con.read_json(
            empty_chunk,
            format="newline_delimited",
            columns={"geometry": "JSON", "properties": "JSON"},
        ).filter("1=0")
        con.register("osm_json_src", init_rel)
        con.execute(init_sql)
        con.execute(transform_sql)
        # Suppress periodic WAL checkpoints during batch staging inserts to avoid write amplification
        con.execute("SET wal_autocheckpoint = '1TB';")
        con.execute("SET checkpoint_threshold = '1TB';")
        con.execute("CREATE TABLE stage AS SELECT * FROM places_export LIMIT 0")
    except Exception as exc:
        raise RuntimeError(
            "DuckDB session bootstrap failed. Check sqlite/staging permissions, "
            "the spatial extension installation and the relations OPL file."
        ) from exc

    total_staged = 0
    total_features = 0
    started = time.time()

    # ------------------------------------------------------------------
    # 3. Stream osmium export, chunked memfs ingest
    # ------------------------------------------------------------------
    osmium_cmd = [
        "osmium",
        *OSM_EXPORT_ARGS,
        args.input,
        "-i",
        "sparse_file_array,%s" % os.path.join(args.tmp_dir, "osmium_idx.tmp"),
    ]
    try:
        proc = subprocess.Popen(
            osmium_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("'osmium' binary not found on PATH; install osmium-tool.") from exc

    chunk_no = 0
    returncode = None
    err = b""
    spatial_wheres = (" WHERE 1=1 " + args.spatial_filter) if args.spatial_filter else ""
    insert_sql = "INSERT INTO stage SELECT * FROM places_export" + spatial_wheres

    try:
        for chunk in iter_jsonl_chunks(proc, chunk_bytes):
            if not chunk.strip():
                continue
            chunk_no += 1
            cstart = time.time()
            rel = con.read_json(
                io.BytesIO(chunk),
                format="newline_delimited",
                maximum_object_size=int(args.max_object_size),
                columns={"geometry": "JSON", "properties": "JSON"},
            )
            # Rebind the shared view source to the in-memory chunk
            con.register("osm_json_src", rel)
            affected = con.execute(insert_sql).fetchone()[0]
            total_staged += affected
            elapsed = time.time() - cstart
            print(
                "[CHUNK %d] %s bytes | %d rows staged | %5.1fs | total rows staged: %d"
                % (chunk_no, len(chunk), affected, elapsed, total_staged),
                flush=True,
            )
    finally:
        _, err = proc.communicate()
        returncode = proc.returncode

    stderr_text = err.decode("utf-8", "replace") if err else ""
    if returncode != 0:
        # signal exit codes (e.g. 137) mean an OOM-killed osmium process
        raise OsmExportError(
            "osmium export failed with exit code %d%s"
            % (returncode, ("\n" + stderr_text[-2000:]) if stderr_text else "")
        )

    total_features = chunk_no
    if total_features == 0:
        raise RuntimeError(
            "No GeoJSON features were received from osmium export; no staging rows. "
            "Aborting without producing an output file (transparent failure policy)."
        )

    # ------------------------------------------------------------------
    # 4. Single final GeoParquet with the full provenance KV_METADATA
    # ------------------------------------------------------------------
    copy_sql = (
        "COPY (SELECT * FROM stage) TO '%s' (\n"
        "    FORMAT PARQUET,\n"
        "    COMPRESSION 'ZSTD',\n"
        "    ROW_GROUP_SIZE 60000,\n"
        "    KV_METADATA {\n"
        "%s\n"
        "    }\n"
        ");"
    ) % (args.output, kv_metadata)
    cstart = time.time()
    con.execute(copy_sql)
    copy_seconds = time.time() - cstart

    if not os.path.exists(args.output):
        raise RuntimeError("Final GeoParquet was not produced: %s" % args.output)

    final_count = con.execute(
        "SELECT count(*) FROM read_parquet('%s')" % args.output.replace("'", "''")
    ).fetchone()[0]
    con.close()

    print(
        "[OK] Streamed %d chunk(s), %d POIs staged, single GeoParquet written: %s (%d rows) in %.0fs"
        % (total_features, total_staged, args.output, final_count, time.time() - started)
    )
    if final_count != total_staged:
        print(
            "[WARN] Staged row count (%d) differs from final parquet row count (%d)"
            % (total_staged, final_count),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("[FATAL] %s" % exc, file=sys.stderr)
        sys.exit(1)