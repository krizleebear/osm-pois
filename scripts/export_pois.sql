-- DuckDB SQL: OSM PBF -> Overture Places-compatible GeoParquet
LOAD spatial;

-- Load Overture category hierarchy from taxonomy CSV
CREATE TEMP TABLE overture_taxonomy AS
SELECT 
    trim(column0) AS overture_cat,
    str_split(replace(replace(trim(column1), '[', ''), ']', ''), ',') AS hierarchy
FROM read_csv('__REPO_ROOT__/mappings/overture_categories.csv', header=False);

-- Load Category Mapping Rules (overture_to_osm_categories)
CREATE TEMP TABLE category_rules AS
SELECT 
    trim(column0) AS overture_cat,
    trim(column1) AS tag_expr,
    split_part(split_part(trim(column1), ',', 1), '=', 1) AS primary_key,
    split_part(split_part(trim(column1), ',', 1), '=', 2) AS primary_val,
    split_part(split_part(trim(column1), ',', 2), '=', 1) AS sub_key,
    split_part(split_part(trim(column1), ',', 2), '=', 2) AS sub_val,
    split_part(split_part(trim(column1), ',', 3), '=', 1) AS sub3_key,
    split_part(split_part(trim(column1), ',', 3), '=', 2) AS sub3_val,
    length(split_part(trim(column1), ',', 2)) AS has_subtag
FROM read_csv('__REPO_ROOT__/mappings/overture_to_osm_categories.csv', header=False);

-- Clean single primary mapping table (prefer exact single tag match, e.g. shop=clothes -> clothing_store)
CREATE TEMP TABLE primary_rules AS
SELECT DISTINCT ON (primary_key, primary_val)
    overture_cat,
    primary_key,
    primary_val
FROM category_rules
ORDER BY primary_key, primary_val, has_subtag ASC, overture_cat ASC;

-- Extract Raw Features from Osmium GeoJSON stream (reconstructs 100% of points, ways, and polygons)
CREATE TEMP TABLE raw_features AS
SELECT 
    'osm:' || json_extract_string(properties, '$.@type') || '/' || json_extract_string(properties, '$.@id') AS id,
    COALESCE(json_extract_string(properties, '$.name'), json_extract_string(properties, '$.brand'), json_extract_string(properties, '$.operator')) AS name,
    json_extract_string(properties, '$.name:en') AS name_en,
    json_extract_string(properties, '$.name:de') AS name_de,
    json_extract_string(properties, '$.amenity') AS amenity,
    json_extract_string(properties, '$.religion') AS religion,
    json_extract_string(properties, '$.denomination') AS denomination,
    json_extract_string(properties, '$.cuisine') AS cuisine,
    json_extract_string(properties, '$.shop') AS shop,
    json_extract_string(properties, '$.tourism') AS tourism,
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
    CASE 
        WHEN ST_GeometryType(ST_GeomFromGeoJSON(geometry)) IN ('POLYGON', 'MULTIPOLYGON') 
        THEN ST_PointOnSurface(ST_GeomFromGeoJSON(geometry)) 
        ELSE ST_GeomFromGeoJSON(geometry) 
    END AS geometry
FROM read_json('__INPUT_JSONL__', 
               format='newline_delimited', 
               columns={'geometry': 'JSON', 'properties': 'JSON'})
WHERE (json_extract_string(properties, '$.name') IS NOT NULL 
       OR json_extract_string(properties, '$.brand') IS NOT NULL 
       OR json_extract_string(properties, '$.operator') IS NOT NULL)
  AND (json_extract_string(properties, '$.amenity') IS NOT NULL 
       OR json_extract_string(properties, '$.shop') IS NOT NULL 
       OR json_extract_string(properties, '$.tourism') IS NOT NULL 
       OR json_extract_string(properties, '$.leisure') IS NOT NULL 
       OR json_extract_string(properties, '$.office') IS NOT NULL 
       OR json_extract_string(properties, '$.craft') IS NOT NULL 
       OR json_extract_string(properties, '$.healthcare') IS NOT NULL 
       OR json_extract_string(properties, '$.historic') IS NOT NULL 
       OR json_extract_string(properties, '$.railway') IS NOT NULL 
       OR json_extract_string(properties, '$.aeroway') IS NOT NULL)
  AND geometry IS NOT NULL
  AND ST_IsValid(ST_GeomFromGeoJSON(geometry));

-- Map Categories and Format into Overture Places GeoParquet
COPY (
    WITH categorized AS (
        SELECT 
            f.*,
            COALESCE(
                -- 1. Cuisine-specific restaurant match (e.g. amenity=restaurant,cuisine=italian -> italian_restaurant)
                CASE WHEN f.amenity = 'restaurant' AND f.cuisine IS NOT NULL THEN
                    (SELECT r.overture_cat FROM category_rules r 
                     WHERE r.primary_key = 'amenity' AND r.primary_val = 'restaurant' 
                       AND r.sub_key = 'cuisine' AND r.sub_val = split_part(f.cuisine, ';', 1) 
                     ORDER BY r.overture_cat ASC
                     LIMIT 1)
                END,
                -- 2. Transit station subtag match (e.g. railway=station,station=subway -> light_rail_and_subway_station)
                CASE WHEN f.railway = 'station' AND f.station IS NOT NULL THEN
                    (SELECT r.overture_cat FROM category_rules r 
                     WHERE r.primary_key = 'railway' AND r.primary_val = 'station' 
                       AND r.sub_key = 'station' AND r.sub_val = f.station 
                     ORDER BY r.overture_cat ASC
                     LIMIT 1)
                END,
                -- 3. Place of worship denomination & religion subtag match (e.g. amenity=place_of_worship,religion=christian,denomination=catholic -> catholic_church)
                CASE WHEN f.amenity = 'place_of_worship' THEN
                    COALESCE(
                        -- 3-tag match: amenity=place_of_worship, religion=..., denomination=...
                        CASE WHEN f.religion IS NOT NULL AND f.denomination IS NOT NULL THEN
                            (SELECT r.overture_cat FROM category_rules r 
                             WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                               AND r.sub_key = 'religion' AND r.sub_val = split_part(f.religion, ';', 1)
                               AND r.sub3_key = 'denomination' AND r.sub3_val = split_part(f.denomination, ';', 1)
                             LIMIT 1)
                        END,
                        -- 2-tag match by denomination: amenity=place_of_worship, denomination=...
                        CASE WHEN f.denomination IS NOT NULL THEN
                            (SELECT r.overture_cat FROM category_rules r 
                             WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                               AND (
                                   (r.sub_key = 'denomination' AND r.sub_val = split_part(f.denomination, ';', 1)) OR
                                   (r.sub3_key = 'denomination' AND r.sub3_val = split_part(f.denomination, ';', 1))
                               )
                             LIMIT 1)
                        END,
                        -- 2-tag match by religion: amenity=place_of_worship, religion=...
                        CASE WHEN f.religion IS NOT NULL THEN
                            (SELECT r.overture_cat FROM category_rules r 
                             WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                               AND r.sub_key = 'religion' AND r.sub_val = split_part(f.religion, ';', 1)
                               AND (r.sub3_key IS NULL OR r.sub3_key = '')
                             LIMIT 1)
                        END
                    )
                END,
                -- 4. Primary tag matches from deterministic rule table
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'amenity' AND r.primary_val = f.amenity),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'shop' AND r.primary_val = f.shop),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'tourism' AND r.primary_val = f.tourism),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'leisure' AND r.primary_val = f.leisure),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'office' AND r.primary_val = f.office),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'craft' AND r.primary_val = f.craft),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'healthcare' AND r.primary_val = f.healthcare),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'historic' AND r.primary_val = f.historic),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'railway' AND r.primary_val = f.railway),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'aeroway' AND r.primary_val = f.aeroway),
                f.amenity,
                f.shop,
                f.tourism,
                f.leisure,
                'point_of_interest'
            ) AS main_category
        FROM raw_features f
    )
    SELECT
        id,
        geometry,
        -- Categories struct
        {'primary': main_category, 'alternate': CAST([] AS VARCHAR[])} AS categories,
        0.8::DOUBLE AS confidence,
        -- Contact arrays
        CASE WHEN website IS NOT NULL THEN [website] ELSE CAST([] AS VARCHAR[]) END AS websites,
        CASE WHEN email IS NOT NULL THEN [email] ELSE CAST([] AS VARCHAR[]) END AS emails,
        CAST([] AS VARCHAR[]) AS socials,
        CASE WHEN phone IS NOT NULL THEN [phone] ELSE CAST([] AS VARCHAR[]) END AS phones,
        -- Brand struct
        {'wikidata': brand_wikidata, 'names': {'primary': brand, 'common': map([], []), 'rules': NULL}} AS brand,
        -- Addresses array
        CASE 
            WHEN addr_street IS NOT NULL OR addr_postcode IS NOT NULL OR addr_city IS NOT NULL 
            THEN [{
                'freeform': CASE WHEN addr_street IS NOT NULL AND addr_housenumber IS NOT NULL THEN addr_street || ' ' || addr_housenumber ELSE addr_street END,
                'locality': addr_city,
                'postcode': addr_postcode,
                'region': NULL,
                'country': '__COUNTRY_CODE__'
            }]
            ELSE CAST([] AS struct(freeform varchar, locality varchar, postcode varchar, region varchar, country varchar)[])
        END AS addresses,
        -- Names struct
        {
            'primary': name,
            'common': map(
                CASE WHEN name_en IS NOT NULL THEN ['en'] ELSE [] END,
                CASE WHEN name_en IS NOT NULL THEN [name_en] ELSE [] END
            ),
            'rules': NULL
        } AS names,
        -- Sources array
        [{
            'property': '',
            'dataset': 'OpenStreetMap',
            'license': 'ODbL-1.0',
            'record_id': id,
            'update_time': NULL,
            'confidence': 1.0::DOUBLE
        }] AS sources,
        'active' AS operating_status,
        main_category AS basic_category,
        {'primary': main_category, 'hierarchy': COALESCE(t.hierarchy, [main_category]), 'alternates': CAST([] AS VARCHAR[])} AS taxonomy,
        1 AS version,
        {
            'xmin': ST_X(geometry),
            'xmax': ST_X(geometry),
            'ymin': ST_Y(geometry),
            'ymax': ST_Y(geometry)
        } AS bbox,
        'places.parquet' AS filename,
        'places' AS theme,
        'place' AS type
    FROM categorized c
    LEFT JOIN overture_taxonomy t ON c.main_category = t.overture_cat
) TO '__OUTPUT_PARQUET__' (FORMAT PARQUET, COMPRESSION 'ZSTD');
