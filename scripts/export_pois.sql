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

-- Extract Raw Features from OSM PBF
CREATE TEMP TABLE raw_features AS
SELECT 
    'osm:node/' || COALESCE(osm_id, '') AS id,
    COALESCE(name, brand, operator) AS name,
    name_en,
    name_de,
    amenity,
    cuisine,
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
    brand_wikidata,
    addr_street,
    addr_housenumber,
    addr_postcode,
    addr_city,
    COALESCE(website, contact_website) AS website,
    COALESCE(phone, contact_phone) AS phone,
    COALESCE(email, contact_email) AS email,
    geom AS geometry
FROM ST_Read(
    '__INPUT_PBF__',
    layer = 'points',
    open_options = ['CONFIG_FILE=__REPO_ROOT__/config/osmconf.ini']
)
WHERE (name IS NOT NULL OR brand IS NOT NULL OR operator IS NOT NULL)
  AND (amenity IS NOT NULL OR shop IS NOT NULL OR tourism IS NOT NULL OR leisure IS NOT NULL OR office IS NOT NULL OR craft IS NOT NULL OR healthcare IS NOT NULL OR historic IS NOT NULL)

UNION ALL

SELECT 
    'osm:way/' || COALESCE(osm_way_id, osm_id, '') AS id,
    COALESCE(name, brand, operator) AS name,
    name_en,
    name_de,
    amenity,
    cuisine,
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
    brand_wikidata,
    addr_street,
    addr_housenumber,
    addr_postcode,
    addr_city,
    COALESCE(website, contact_website) AS website,
    COALESCE(phone, contact_phone) AS phone,
    COALESCE(email, contact_email) AS email,
    CASE WHEN ST_IsValid(geom) THEN ST_PointOnSurface(geom) ELSE NULL END AS geometry
FROM ST_Read(
    '__INPUT_PBF__',
    layer = 'multipolygons',
    open_options = ['CONFIG_FILE=__REPO_ROOT__/config/osmconf.ini']
)
WHERE (name IS NOT NULL OR brand IS NOT NULL OR operator IS NOT NULL)
  AND (amenity IS NOT NULL OR shop IS NOT NULL OR tourism IS NOT NULL OR leisure IS NOT NULL OR office IS NOT NULL OR craft IS NOT NULL OR healthcare IS NOT NULL OR historic IS NOT NULL)
  AND ST_IsValid(geom);

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
                     LIMIT 1)
                END,
                -- 2. Primary tag matches from deterministic rule table
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'amenity' AND r.primary_val = f.amenity),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'shop' AND r.primary_val = f.shop),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'tourism' AND r.primary_val = f.tourism),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'leisure' AND r.primary_val = f.leisure),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'office' AND r.primary_val = f.office),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'craft' AND r.primary_val = f.craft),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'healthcare' AND r.primary_val = f.healthcare),
                (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'historic' AND r.primary_val = f.historic),
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
