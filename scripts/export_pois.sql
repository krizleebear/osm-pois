-- DuckDB SQL: OSM PBF -> Overture Places-compatible GeoParquet
LOAD spatial;

-- Memory and thread bounds for CI/CD runner environments (Azure DevOps 7GB limit)
SET max_memory = '4200MB';
SET temp_directory = '__TEMP_DIR__';
SET preserve_insertion_order = false;
SET threads = 1;
SET allocator_background_threads = true;
SET write_buffer_row_group_count = 1;
SET write_buffer_row_group_memory_limit = '128MB';

-- Configure repository root for loading external mappings
SET VARIABLE repo_root = '__REPO_ROOT__';

-- Load modular SQL components
.read __REPO_ROOT__/scripts/sql/01_taxonomy.sql
.read __REPO_ROOT__/scripts/sql/02_macros.sql
.read __REPO_ROOT__/scripts/sql/03_categorization.sql
.read __REPO_ROOT__/scripts/sql/04_confidence.sql
.read __REPO_ROOT__/scripts/sql/05_relations.sql

-- Build Inverted Relation Membership Index from extracted OPL relations stream
CREATE TEMP TABLE IF NOT EXISTS raw_rel_lines AS 
SELECT col0 AS line 
FROM read_csv('__INPUT_RELATIONS_OPL__', columns={'col0': 'VARCHAR'}, quote='', escape='', delim='\n', auto_detect=false);

CREATE TEMP TABLE IF NOT EXISTS osm_relation_members AS
WITH parsed_rels AS (
    SELECT 
        'osm:relation/' || regexp_extract(line, '^r([0-9]+)', 1) AS relation_id,
        regexp_extract(line, ' T([^ ]*)', 1) AS raw_tags,
        regexp_extract(line, ' M([^ ]*)', 1) AS raw_members
    FROM raw_rel_lines
    WHERE line LIKE 'r%'
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

-- Stream Osmium GeoJSON directly into Overture Places GeoParquet (Zero Intermediate Materialization)
COPY (
    WITH base_json AS (
        SELECT 
            ST_GeomFromGeoJSON(geometry) AS geom,
            properties
        FROM read_json('__INPUT_JSONL__', 
                       format='newline_delimited', 
                       maximum_object_size=268435456,
                       columns={'geometry': 'JSON', 'properties': 'JSON'})
        WHERE is_poi_candidate(properties)
          AND geometry IS NOT NULL
    ),
    valid_geoms AS (
        SELECT 
            geom,
            properties
        FROM base_json
        WHERE geom IS NOT NULL AND ST_IsValid(geom)
    ),
    raw_features AS (
        SELECT 
            'osm:' || json_extract_string(properties, '$.@type') || '/' || json_extract_string(properties, '$.@id') AS id,
            TRY_CAST(json_extract_string(properties, '$.@version') AS INTEGER) AS osm_version,
            CASE 
                WHEN json_extract_string(properties, '$.@timestamp') IS NOT NULL 
                THEN strftime(to_timestamp(TRY_CAST(json_extract_string(properties, '$.@timestamp') AS BIGINT)), '%Y-%m-%dT%H:%M:%SZ') 
                ELSE NULL 
            END AS osm_timestamp,
            resolve_poi_name(properties) AS name,
            osm_names_common(properties) AS names_common,
            osm_names_rules(properties) AS names_rules,
            osm_brand_common(properties) AS brand_common,
            json_extract_string(properties, '$.amenity') AS amenity,
            json_extract_string(properties, '$.religion') AS religion,
            json_extract_string(properties, '$.denomination') AS denomination,
            json_extract_string(properties, '$.cuisine') AS cuisine,
            json_extract_string(properties, '$.shop') AS shop,
            json_extract_string(properties, '$.tourism') AS tourism,
            json_extract_string(properties, '$.information') AS information,
            json_extract_string(properties, '$.entrance') AS entrance,
            json_extract_string(properties, '$.leisure') AS leisure,
            json_extract_string(properties, '$.office') AS office,
            json_extract_string(properties, '$.craft') AS craft,
            json_extract_string(properties, '$.healthcare') AS healthcare,
            json_extract_string(properties, '$.historic') AS historic,
            json_extract_string(properties, '$.sport') AS sport,
            json_extract_string(properties, '$.aeroway') AS aeroway,
            json_extract_string(properties, '$.railway') AS railway,
            json_extract_string(properties, '$.station') AS station,
            json_extract_string(properties, '$.man_made') AS man_made,
            json_extract_string(properties, '$.emergency') AS emergency,
            json_extract_string(properties, '$.highway') AS highway,
            json_extract_string(properties, '$.operator') AS operator,
            json_extract_string(properties, '$.ref') AS ref,
            json_extract_string(properties, '$.brand') AS brand,
            json_extract_string(properties, '$.brand:wikidata') AS brand_wikidata,
            json_extract_string(properties, '$.addr:street') AS addr_street,
            json_extract_string(properties, '$.addr:housenumber') AS addr_housenumber,
            json_extract_string(properties, '$.addr:postcode') AS addr_postcode,
            json_extract_string(properties, '$.addr:city') AS addr_city,
            COALESCE(json_extract_string(properties, '$.website'), json_extract_string(properties, '$.contact:website')) AS website,
            COALESCE(json_extract_string(properties, '$.phone'), json_extract_string(properties, '$.contact:phone')) AS phone,
            COALESCE(json_extract_string(properties, '$.email'), json_extract_string(properties, '$.contact:email')) AS email,
            extract_socials(properties) AS socials,
            -- Extended operational attributes (Superset extension)
            json_extract_string(properties, '$.opening_hours') AS opening_hours,
            json_extract_string(properties, '$.wheelchair') AS wheelchair,
            extract_payment_methods(properties) AS payment_methods,
            extract_poi_level(properties) AS level,
            json_extract_string(properties, '$.delivery') AS delivery,
            json_extract_string(properties, '$.takeaway') AS takeaway,
            osm_raw_tags(properties) AS tags,
            -- Metric footprint area (m², integer) of polygon/multipolygon POI geometries;
            -- NULL for point/node features (see osm_area_sqm in 02_macros.sql)
            osm_area_sqm(geom) AS area_m2,
            -- Upstream POI confidence scoring
            calculate_poi_confidence(
                properties,
                ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON'),
                TRY_CAST(json_extract_string(properties, '$.@version') AS INTEGER),
                CASE 
                    WHEN json_extract_string(properties, '$.@timestamp') IS NOT NULL 
                    THEN strftime(to_timestamp(TRY_CAST(json_extract_string(properties, '$.@timestamp') AS BIGINT)), '%Y-%m-%dT%H:%M:%SZ') 
                    ELSE NULL 
                END,
                COALESCE(json_extract_string(properties, '$.website'), json_extract_string(properties, '$.contact:website')) IS NOT NULL,
                COALESCE(json_extract_string(properties, '$.phone'), json_extract_string(properties, '$.contact:phone')) IS NOT NULL
            ) AS confidence,
            CASE 
                WHEN ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON') 
                THEN ST_PointOnSurface(geom) 
                ELSE geom 
            END AS geometry
        FROM valid_geoms
    ),
    categorized AS (
        SELECT 
            f.*,
            resolve_poi_category(
                f.amenity, f.shop, f.tourism, f.leisure, f.office,
                f.craft, f.healthcare, f.historic, f.railway, f.aeroway,
                f.cuisine, f.station, f.religion, f.denomination,
                f.information, f.name,
                f.man_made, f.emergency,
                f.highway
            ) AS main_category
        FROM raw_features f
    ),
    with_alternates AS (
        SELECT
            c.*,
            resolve_alternate_categories(
                c.main_category,
                c.amenity, c.shop, c.tourism, c.leisure, c.office,
                c.craft, c.healthcare, c.historic, c.highway,
                c.cuisine, c.sport
            ) AS alternate_categories
        FROM categorized c
    ),
    with_relations AS (
        SELECT 
            c.*,
            rel.relation_id,
            rel.member_role,
            rel.parent_osm_id,
            rel.parent_feature_kind,
            resolve_access_type(c.amenity, c.entrance, c.railway, rel.member_role, rel.parent_feature_kind) AS access_type
        FROM with_alternates c
        LEFT JOIN osm_relation_members rel ON c.id = rel.member_id
    )
    SELECT
        id,
        geometry,
        -- Categories struct
        {'primary': main_category, 'alternate': alternate_categories} AS categories,
        confidence,
        -- Contact arrays
        CASE WHEN website IS NOT NULL THEN [website] ELSE CAST([] AS VARCHAR[]) END AS websites,
        CASE WHEN email IS NOT NULL THEN [email] ELSE CAST([] AS VARCHAR[]) END AS emails,
        socials,
        CASE WHEN phone IS NOT NULL THEN [phone] ELSE CAST([] AS VARCHAR[]) END AS phones,
        -- Brand struct
        {
            'wikidata': brand_wikidata, 
            'names': {
                'primary': brand, 
                'common': brand_common, 
                'rules': empty_rules()
            }
        } AS brand,
        -- Addresses array
        format_address(addr_street, addr_housenumber, addr_city, addr_postcode, '__COUNTRY_CODE__') AS addresses,
        -- Names struct
        {
            'primary': name,
            'common': names_common,
            'rules': names_rules
        } AS names,
        -- Sources array
        [{
            'property': '',
            'dataset': 'OpenStreetMap',
            'license': 'ODbL-1.0',
            'record_id': id,
            'update_time': osm_timestamp,
            'confidence': 1.0::DOUBLE
        }] AS sources,
        'active' AS operating_status,
        main_category AS basic_category,
        {'primary': main_category, 'hierarchy': COALESCE(getvariable('taxonomy_lookup').hierarchy_map[main_category], [main_category]), 'alternates': alternate_categories} AS taxonomy,
        COALESCE(osm_version, 1) AS version,
        {
            'xmin': ST_X(geometry),
            'xmax': ST_X(geometry),
            'ymin': ST_Y(geometry),
            'ymax': ST_Y(geometry)
        } AS bbox,
        'places.parquet' AS filename,
        'places' AS theme,
        'place' AS type,
        -- Extended Operational Attributes (Non-breaking Superset Extension)
        ref,
        opening_hours,
        cuisine,
        wheelchair,
        payment_methods,
        level,
        operator,
        delivery,
        takeaway,
        area_m2,
        tags,
        -- Parent & Relation Membership Attributes (Superset Extension)
        parent_osm_id,
        parent_feature_kind,
        relation_id,
        member_role,
        access_type
    FROM with_relations c
    WHERE 1=1 __SPATIAL_FILTER__
) TO '__OUTPUT_PARQUET__' (
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
