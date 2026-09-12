-- DuckDB SQL: OSM PBF -> Overture Places-compatible GeoParquet
LOAD spatial;

-- Load Overture category hierarchy from taxonomy CSV
CREATE TEMP TABLE overture_taxonomy AS
SELECT 
    trim(split_part(column0, ';', 1)) AS overture_cat,
    str_split(replace(replace(trim(split_part(column0, ';', 2)), '[', ''), ']', ''), ',') AS hierarchy
FROM read_csv('__REPO_ROOT__/mappings/overture_categories.csv', header=False);

-- Load Category Mapping Rules (overture_to_osm_categories)
-- Format: overture_category;key=val,key2=val2
CREATE TEMP TABLE category_rules AS
WITH raw_rules AS (
    SELECT 
        trim(split_part(column0, ';', 1)) AS overture_cat,
        trim(split_part(column0, ';', 2)) AS tag_expr
    FROM read_csv('__REPO_ROOT__/mappings/overture_to_osm_categories.csv', header=False)
)
SELECT 
    overture_cat,
    tag_expr,
    -- Match primary key/value for fast joining
    split_part(split_part(tag_expr, ',', 1), '=', 1) AS primary_key,
    split_part(split_part(tag_expr, ',', 1), '=', 2) AS primary_val
FROM raw_rules;

-- Extract Raw Features from OSM PBF
CREATE TEMP TABLE raw_features AS
SELECT 
    'osm:node/' || osm_id AS id,
    name,
    "name:en" AS name_en,
    "name:de" AS name_de,
    amenity,
    shop,
    tourism,
    leisure,
    office,
    craft,
    healthcare,
    historic,
    sport,
    aeroway,
    operator,
    brand,
    "brand:wikidata" AS brand_wikidata,
    "addr:street" AS addr_street,
    "addr:housenumber" AS addr_housenumber,
    "addr:postcode" AS addr_postcode,
    "addr:city" AS addr_city,
    COALESCE(website, "contact:website") AS website,
    COALESCE(phone, "contact:phone") AS phone,
    COALESCE(email, "contact:email") AS email,
    geom AS geometry
FROM ST_Read(
    '__INPUT_PBF__',
    layer = 'points',
    open_options = ['CONFIG_FILE=__REPO_ROOT__/config/osmconf.ini']
)
WHERE name IS NOT NULL 
  AND (amenity IS NOT NULL OR shop IS NOT NULL OR tourism IS NOT NULL OR leisure IS NOT NULL OR office IS NOT NULL OR craft IS NOT NULL OR healthcare IS NOT NULL OR historic IS NOT NULL)

UNION ALL

SELECT 
    'osm:way/' || osm_id AS id,
    name,
    "name:en" AS name_en,
    "name:de" AS name_de,
    amenity,
    shop,
    tourism,
    leisure,
    office,
    craft,
    healthcare,
    historic,
    sport,
    aeroway,
    operator,
    brand,
    "brand:wikidata" AS brand_wikidata,
    "addr:street" AS addr_street,
    "addr:housenumber" AS addr_housenumber,
    "addr:postcode" AS addr_postcode,
    "addr:city" AS addr_city,
    COALESCE(website, "contact:website") AS website,
    COALESCE(phone, "contact:phone") AS phone,
    COALESCE(email, "contact:email") AS email,
    CASE WHEN ST_IsValid(geom) THEN ST_PointOnSurface(geom) ELSE NULL END AS geometry
FROM ST_Read(
    '__INPUT_PBF__',
    layer = 'multipolygons',
    open_options = ['CONFIG_FILE=__REPO_ROOT__/config/osmconf.ini']
)
WHERE name IS NOT NULL 
  AND (amenity IS NOT NULL OR shop IS NOT NULL OR tourism IS NOT NULL OR leisure IS NOT NULL OR office IS NOT NULL OR craft IS NOT NULL OR healthcare IS NOT NULL OR historic IS NOT NULL)
  AND ST_IsValid(geom);

-- Map Categories and Format into Overture Places GeoParquet
COPY (
    WITH categorized AS (
        SELECT 
            f.*,
            COALESCE(
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'amenity' AND r.primary_val = f.amenity LIMIT 1),
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'shop' AND r.primary_val = f.shop LIMIT 1),
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'tourism' AND r.primary_val = f.tourism LIMIT 1),
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'leisure' AND r.primary_val = f.leisure LIMIT 1),
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'office' AND r.primary_val = f.office LIMIT 1),
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'craft' AND r.primary_val = f.craft LIMIT 1),
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'healthcare' AND r.primary_val = f.healthcare LIMIT 1),
                (SELECT r.overture_cat FROM category_rules r WHERE r.primary_key = 'historic' AND r.primary_val = f.historic LIMIT 1),
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
