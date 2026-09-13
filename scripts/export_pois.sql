-- DuckDB SQL: OSM PBF -> Overture Places-compatible GeoParquet
LOAD spatial;

-- Configure repository root for loading external mappings
SET VARIABLE repo_root = '__REPO_ROOT__';

-- Load modular SQL components
.read __REPO_ROOT__/scripts/sql/01_taxonomy.sql
.read __REPO_ROOT__/scripts/sql/02_macros.sql
.read __REPO_ROOT__/scripts/sql/03_categorization.sql
.read __REPO_ROOT__/scripts/sql/04_confidence.sql

-- Extract Raw Features from Osmium GeoJSON stream (reconstructs 100% of points, ways, and polygons)
CREATE TEMP TABLE raw_features AS
WITH base_json AS (
    SELECT 
        geometry,
        properties
    FROM read_json('__INPUT_JSONL__', 
                   format='newline_delimited', 
                   columns={'geometry': 'JSON', 'properties': 'JSON'})
    WHERE is_poi_candidate(properties)
      AND geometry IS NOT NULL
      AND ST_IsValid(ST_GeomFromGeoJSON(geometry))
)
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
    osm_brand_common(properties) AS brand_common,
    json_extract_string(properties, '$.amenity') AS amenity,
    json_extract_string(properties, '$.religion') AS religion,
    json_extract_string(properties, '$.denomination') AS denomination,
    json_extract_string(properties, '$.cuisine') AS cuisine,
    json_extract_string(properties, '$.shop') AS shop,
    json_extract_string(properties, '$.tourism') AS tourism,
    json_extract_string(properties, '$.information') AS information,
    json_extract_string(properties, '$.leisure') AS leisure,
    json_extract_string(properties, '$.office') AS office,
    json_extract_string(properties, '$.craft') AS craft,
    json_extract_string(properties, '$.healthcare') AS healthcare,
    json_extract_string(properties, '$.historic') AS historic,
    json_extract_string(properties, '$.sport') AS sport,
    json_extract_string(properties, '$.aeroway') AS aeroway,
    json_extract_string(properties, '$.railway') AS railway,
    json_extract_string(properties, '$.station') AS station,
    json_extract_string(properties, '$.operator') AS operator,
    json_extract_string(properties, '$.brand') AS brand,
    json_extract_string(properties, '$.brand:wikidata') AS brand_wikidata,
    json_extract_string(properties, '$.addr:street') AS addr_street,
    json_extract_string(properties, '$.addr:housenumber') AS addr_housenumber,
    json_extract_string(properties, '$.addr:postcode') AS addr_postcode,
    json_extract_string(properties, '$.addr:city') AS addr_city,
    COALESCE(json_extract_string(properties, '$.website'), json_extract_string(properties, '$.contact:website')) AS website,
    COALESCE(json_extract_string(properties, '$.phone'), json_extract_string(properties, '$.contact:phone')) AS phone,
    COALESCE(json_extract_string(properties, '$.email'), json_extract_string(properties, '$.contact:email')) AS email,
    -- Extended operational attributes (Superset extension)
    json_extract_string(properties, '$.opening_hours') AS opening_hours,
    json_extract_string(properties, '$.wheelchair') AS wheelchair,
    extract_payment_methods(properties) AS payment_methods,
    extract_poi_level(properties) AS level,
    json_extract_string(properties, '$.delivery') AS delivery,
    json_extract_string(properties, '$.takeaway') AS takeaway,
    -- Upstream POI confidence scoring
    calculate_poi_confidence(
        properties,
        ST_GeometryType(ST_GeomFromGeoJSON(geometry)) IN ('POLYGON', 'MULTIPOLYGON'),
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
        WHEN ST_GeometryType(ST_GeomFromGeoJSON(geometry)) IN ('POLYGON', 'MULTIPOLYGON') 
        THEN ST_PointOnSurface(ST_GeomFromGeoJSON(geometry)) 
        ELSE ST_GeomFromGeoJSON(geometry) 
    END AS geometry
FROM base_json;

-- Map Categories and Format into Overture Places GeoParquet
COPY (
    WITH categorized AS (
        SELECT 
            f.*,
            resolve_poi_category(
                f.amenity, f.shop, f.tourism, f.leisure, f.office,
                f.craft, f.healthcare, f.historic, f.railway, f.aeroway,
                f.cuisine, f.station, f.religion, f.denomination,
                f.information, f.name
            ) AS main_category
        FROM raw_features f
    )
    SELECT
        id,
        geometry,
        -- Categories struct
        {'primary': main_category, 'alternate': CAST([] AS VARCHAR[])} AS categories,
        confidence,
        -- Contact arrays
        CASE WHEN website IS NOT NULL THEN [website] ELSE CAST([] AS VARCHAR[]) END AS websites,
        CASE WHEN email IS NOT NULL THEN [email] ELSE CAST([] AS VARCHAR[]) END AS emails,
        CAST([] AS VARCHAR[]) AS socials,
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
            'rules': empty_rules()
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
        {'primary': main_category, 'hierarchy': COALESCE(t.hierarchy, [main_category]), 'alternates': CAST([] AS VARCHAR[])} AS taxonomy,
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
        opening_hours,
        cuisine,
        wheelchair,
        payment_methods,
        level,
        operator,
        delivery,
        takeaway
    FROM categorized c
    LEFT JOIN overture_taxonomy t ON c.main_category = t.overture_cat
) TO '__OUTPUT_PARQUET__' (
    FORMAT PARQUET, 
    COMPRESSION 'ZSTD',
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
