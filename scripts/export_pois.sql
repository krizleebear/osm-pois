-- DuckDB SQL: OSM PBF -> Overture Places-compatible GeoParquet
LOAD spatial;

-- Memory and thread bounds for CI/CD runner environments (Azure DevOps 7GB limit).
--
-- ARCHITECTURAL MEMORY CALIBRATION & LESSONS LEARNED (DE Extract: 8.3M features -> 3.18M POIs):
-- 1. Blocking Pipeline Breakers:
--    Global window functions (e.g. ROW_NUMBER() OVER (...) in deduplication CTEs) force
--    DuckDB to materialize all rows in RAM before writing any Parquet output. This caused
--    the initial CI OOM ("failed to allocate 394.9 MiB (3.7 GiB/3.9 GiB used)"). The pipeline
--    must remain 100% streaming (PROJECTION -> HASH_JOIN -> COPY_TO_FILE).
-- 2. Buffer Manager & Atomic Allocation Sizing:
--    read_json(..., maximum_object_size=N) pre-allocates internal stream buffers of 2 * N.
--    At N = 64MB (67108864), the allocation chunk is 127.9 MiB. At N = 256MB, it is 394.9 MiB.
--    DuckDB does not actively free blocks during streaming if current memory < max_memory.
--    Capping max_memory too tightly (e.g. 2600MB or 3800MB) causes DuckDB's working set to reach
--    the cap (e.g. 3.4 GiB / 3.5 GiB used), at which point the next 127.9 MiB atomic buffer
--    request fails with an internal BufferManager OutOfMemoryError, even with gigabytes of host RAM free!
-- 3. 7.0 GB Azure DevOps Runner Budget:
--    - Osmium export (-i sparse_file_array): ~116 MB on nodes, peaks at ~730 MB on ways/relations.
--    - DuckDB streaming working set: peaks at ~4.5 - 4.7 GB RSS over 8.3M features.
--    - Host OS, page cache, pipe buffers: ~1.5 - 1.8 GB free headroom.
--    SET max_memory = '4800MB' is the calibrated sweet spot: it gives DuckDB ~4.5 GiB headroom
--    to prevent internal allocation choke, while keeping combined container RSS (~5.4 GB) safely
--    below the 7.0 GB physical container limit (preventing Linux SIGKILL / Exit 137).
-- 4. Cache & Row Group Limits:
--    - SET enable_external_file_cache = false prevents written Parquet pages from lingering in RAM.
--    - SET write_buffer_row_group_count = 1 flushes row groups incrementally.
--    - SET write_buffer_row_group_memory_limit = '64MB' avoids oversized row group buffers.
SET max_memory = '4800MB';
SET temp_directory = '__TEMP_DIR__';
SET preserve_insertion_order = false;
SET threads = 1;
SET allocator_background_threads = true;
SET write_buffer_row_group_count = 1;
SET write_buffer_row_group_memory_limit = '64MB';
SET enable_external_file_cache = false;

-- Maximum size of a single GeoJSON sequence record accepted by the JSON reader.
-- Measured: DuckDB's JSON reader pre-allocates several buffers of this size, so
-- this setting is the dominant contributor to the fixed memory floor
-- (256 MB -> ~1120 MB, 64 MB -> ~490 MB). 64 MB keeps ample headroom above the
-- largest GeoJSON record observed on large extracts (multipolygon relations of
-- ~38 MB on the continental US) while removing ~640 MB of fixed overhead.
-- Override per region via OSM_POIS_MAX_OBJECT_SIZE (bytes) in entrypoint.sh.

-- Configure repository root for loading external mappings
SET VARIABLE repo_root = '__REPO_ROOT__';

-- Load modular SQL components
.read __REPO_ROOT__/scripts/sql/01_taxonomy.sql
.read __REPO_ROOT__/scripts/sql/02_macros.sql
.read __REPO_ROOT__/scripts/sql/03_categorization.sql
.read __REPO_ROOT__/scripts/sql/04_confidence.sql
.read __REPO_ROOT__/scripts/sql/05_relations.sql

-- Build Inverted Relation Membership Index from extracted OPL relations stream
CREATE TEMP TABLE IF NOT EXISTS osm_relation_members AS
WITH parsed_rels AS (
    SELECT 
        'osm:relation/' || regexp_extract(col0, '^r([0-9]+)', 1) AS relation_id,
        regexp_extract(col0, ' T([^ ]*)', 1) AS raw_tags,
        regexp_extract(col0, ' M([^ ]*)', 1) AS raw_members
    FROM read_csv('__INPUT_RELATIONS_OPL__', columns={'col0': 'VARCHAR'}, quote='', escape='', delim='\n', auto_detect=false)
    WHERE col0 LIKE 'r%'
),
tag_split AS (
    SELECT 
        relation_id,
        raw_members,
        regexp_extract(raw_tags, '(^|,)type=([^,]*)', 2) AS relation_type,
        regexp_extract(raw_tags, '(^|,)site=([^,]*)', 2) AS site_type,
        regexp_extract(raw_tags, '(^|,)name=([^,]*)', 2) AS rel_name
    FROM parsed_rels
),
members_expanded AS (
    SELECT 
        relation_id,
        relation_type,
        site_type,
        rel_name,
        unnest(string_split(raw_members, ',')) AS member_str
    FROM tag_split
    WHERE raw_members != ''
),
member_parsed AS (
    SELECT 
        relation_id,
        relation_type,
        site_type,
        rel_name,
        'osm:' || CASE WHEN substring(member_str, 1, 1) = 'n' THEN 'node'
                       WHEN substring(member_str, 1, 1) = 'w' THEN 'way'
                       ELSE 'relation' END
               || '/' || regexp_extract(member_str, '^[nwr]([0-9]+)', 1) AS member_id,
        split_part(member_str, '@', 2) AS member_role
    FROM members_expanded
    WHERE member_str != ''
),
parent_candidates AS (
    SELECT 
        relation_id,
        member_id AS candidate_parent_id,
        ROW_NUMBER() OVER (
            PARTITION BY relation_id 
            ORDER BY 
                CASE 
                    WHEN member_role IN ('parking', 'perimeter', 'outer', 'building', 'site') THEN 1
                    WHEN member_id LIKE 'osm:way/%' OR member_id LIKE 'osm:relation/%' THEN 2
                    ELSE 3
                END,
                member_id
        ) AS rank
    FROM member_parsed
    WHERE member_role NOT IN ('entrance', 'exit', 'entry', 'access')
),
primary_parent AS (
    SELECT relation_id, candidate_parent_id 
    FROM parent_candidates 
    WHERE rank = 1
),
ranked_members AS (
    SELECT 
        m.member_id,
        m.relation_id,
        m.member_role,
        CASE 
            WHEN m.member_id = p.candidate_parent_id THEN NULL
            ELSE p.candidate_parent_id 
        END AS parent_osm_id,
        CASE 
            WHEN m.member_id != p.candidate_parent_id AND p.candidate_parent_id IS NOT NULL 
            THEN COALESCE(NULLIF(m.site_type, ''), NULLIF(m.relation_type, ''))
            ELSE NULL 
        END AS parent_feature_kind,
        ROW_NUMBER() OVER (
            PARTITION BY m.member_id
            ORDER BY 
                CASE 
                    WHEN m.relation_type = 'parking' OR m.site_type = 'parking' THEN 1
                    WHEN m.relation_type = 'site' THEN 2
                    WHEN m.relation_type = 'building' THEN 3
                    WHEN m.relation_type = 'associatedStreet' THEN 4
                    WHEN m.relation_type = 'cluster' THEN 5
                    ELSE 6
                END,
                m.relation_id
        ) AS rel_rank
    FROM member_parsed m
    LEFT JOIN primary_parent p ON m.relation_id = p.relation_id
)
SELECT 
    member_id,
    relation_id,
    member_role,
    parent_osm_id,
    parent_feature_kind
FROM ranked_members
WHERE rel_rank = 1;

-- STREAMING INVARIANT: Pin the hash-join build side to osm_relation_members.
-- A named pipe has no file size, so DuckDB estimates the read_json() stream at only
-- ~42 rows, while osm_relation_members holds ~154k rows on DE. Left to itself, the
-- build_side_probe_side optimizer then swaps the LEFT JOIN below and builds the hash
-- table over the ENTIRE POI stream, turning the streaming COPY into a full in-memory
-- materialization (linear RSS growth until "failed to allocate ... (4.4 GiB/4.4 GiB used)"
-- on DE/US). With the optimizer disabled, the written order is kept: the stream is the
-- probe side (left) and the small relation index is the build side (right).
SET disabled_optimizers = 'build_side_probe_side';

-- Input source indirection (swappable):
--   * CLI/FIFO streaming path: bind read_json() to the named pipe below.
--   * Python streaming driver: registers an in-memory BytesIO chunk under the same
--     view name (osm_json_src) per chunk; the FIFO view definition is stripped there
--     (registering under an existing view name conflicts with the catalog).
-- The two activation paths are mutually exclusive and share every downstream rule.
CREATE OR REPLACE TEMP VIEW osm_json_src AS
    SELECT * FROM read_json('__INPUT_JSONL__',
                            format='newline_delimited',
                            maximum_object_size=__MAX_OBJECT_SIZE__,
                            columns={'geometry': 'JSON', 'properties': 'JSON'});

-- Spatial-filter boundary (+ region scale) consumed by the places_export projection.
-- Injected via sed for the CLI/FIFO path; substituted inline by the Python driver.
SET VARIABLE country_code = '__COUNTRY_CODE__';

-- Stream Osmium GeoJSON directly into Overture Places GeoParquet (Zero Intermediate Materialization)
-- The places_export transform view (single source of truth) is defined in:
.read __REPO_ROOT__/scripts/sql/06_places_transform.sql

COPY (SELECT * FROM places_export WHERE 1=1 __SPATIAL_FILTER__) TO '__OUTPUT_PARQUET__' (

    FORMAT PARQUET, 
    COMPRESSION 'ZSTD',
    ROW_GROUP_SIZE 60000,
    KV_METADATA {
        'source': 'OpenStreetMap',
        'origin': 'OpenStreetMap (https://www.openstreetmap.org)',
        'dataset': 'OpenStreetMap POIs (Overture Places Schema Compatible)',
        'attribution': '© OpenStreetMap contributors',
        'attribution_url': 'https://www.openstreetmap.org/copyright',
        'license': 'ODbL-1.0 (https://opendatacommons.org/licenses/odbl/)',
        'license_url': 'https://opendatacommons.org/licenses/odbl/',
        'copyright': 'Data © OpenStreetMap contributors, licensed under Open Data Commons Open Database License 1.0 (ODbL)',
        'schema': 'Overture Maps theme=places / type=place',
        'schema_url': 'https://overturemaps.org/schema/',
        'schema_license': 'CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/)',
        'schema_license_url': 'https://creativecommons.org/licenses/by/4.0/',
        'schema_attribution': 'Schema specification © Overture Maps Foundation, licensed under Creative Commons Attribution 4.0 International (CC-BY-4.0)',
        'compiler': 'osm-pois (https://github.com/krizleebear/osm-pois)',
        'compiler_version': '__BUILD_VERSION__',
        'country_code': '__COUNTRY_CODE__',
        'exported_at': '__EXPORT_TIMESTAMP__'
    }
);
