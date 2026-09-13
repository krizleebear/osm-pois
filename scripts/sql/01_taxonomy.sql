-- 01_taxonomy.sql — Overture Taxonomy & Category Mapping Rules
-- Loads Overture category taxonomy and builds deduplicated OSM-to-Overture mapping tables.

-- Load Overture category hierarchy from taxonomy CSV
CREATE TEMP TABLE IF NOT EXISTS overture_taxonomy AS
SELECT 
    trim(column0) AS overture_cat,
    str_split(replace(replace(trim(column1), '[', ''), ']', ''), ',') AS hierarchy
FROM read_csv(COALESCE(getvariable('repo_root'), '.') || '/mappings/overture_categories.csv', header=False);

-- Load Category Mapping Rules (overture_to_osm_categories)
CREATE TEMP TABLE IF NOT EXISTS category_rules AS
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
FROM read_csv(COALESCE(getvariable('repo_root'), '.') || '/mappings/overture_to_osm_categories.csv', header=False);

-- Clean single primary mapping table (prefer exact single tag match, e.g. shop=clothes -> clothing_store)
CREATE TEMP TABLE IF NOT EXISTS primary_rules AS
SELECT DISTINCT ON (primary_key, primary_val)
    overture_cat,
    primary_key,
    primary_val
FROM category_rules
WHERE NOT (primary_key = 'tourism' AND primary_val = 'information')
ORDER BY primary_key, primary_val, has_subtag ASC, overture_cat ASC;

-- Fast in-memory dictionary lookups for category resolution (O(1) map access, zero nested hash joins)
CREATE TEMP TABLE IF NOT EXISTS taxonomy_lookup AS
SELECT {
    'primary_map': (
        SELECT MAP(list(k), list(v)) FROM (
            SELECT primary_key || '=' || primary_val AS k, overture_cat AS v FROM primary_rules
        )
    ),
    'cuisine_map': (
        SELECT MAP(list(sub_val), list(overture_cat)) FROM (
            SELECT DISTINCT ON (sub_val) sub_val, overture_cat
            FROM category_rules
            WHERE primary_key = 'amenity' AND primary_val = 'restaurant' AND sub_key = 'cuisine'
            ORDER BY sub_val, overture_cat ASC
        )
    ),
    'station_map': (
        SELECT MAP(list(sub_val), list(overture_cat)) FROM (
            SELECT DISTINCT ON (sub_val) sub_val, overture_cat
            FROM category_rules
            WHERE primary_key = 'railway' AND primary_val = 'station' AND sub_key = 'station'
            ORDER BY sub_val, overture_cat ASC
        )
    ),
    'worship_rel_denom_map': (
        SELECT MAP(list(rel_denom), list(overture_cat)) FROM (
            SELECT DISTINCT ON (sub_val, sub3_val) sub_val || '=' || sub3_val AS rel_denom, overture_cat
            FROM category_rules
            WHERE primary_key = 'amenity' AND primary_val = 'place_of_worship' AND sub_key = 'religion' AND sub3_key = 'denomination'
            ORDER BY sub_val, sub3_val, overture_cat ASC
        )
    ),
    'worship_denom_map': (
        SELECT MAP(list(denom), list(overture_cat)) FROM (
            SELECT DISTINCT ON (denom) denom, overture_cat FROM (
                SELECT sub_val AS denom, overture_cat FROM category_rules WHERE primary_key = 'amenity' AND primary_val = 'place_of_worship' AND sub_key = 'denomination'
                UNION ALL
                SELECT sub3_val AS denom, overture_cat FROM category_rules WHERE primary_key = 'amenity' AND primary_val = 'place_of_worship' AND sub3_key = 'denomination'
            ) ORDER BY denom, overture_cat ASC
        )
    ),
    'worship_religion_map': (
        SELECT MAP(list(sub_val), list(overture_cat)) FROM (
            SELECT DISTINCT ON (sub_val) sub_val, overture_cat
            FROM category_rules
            WHERE primary_key = 'amenity' AND primary_val = 'place_of_worship' AND sub_key = 'religion' AND (sub3_key IS NULL OR sub3_key = '')
            ORDER BY sub_val, overture_cat ASC
        )
    ),
    'hierarchy_map': (
        SELECT MAP(list(overture_cat), list(hierarchy)) FROM overture_taxonomy
    )
} AS lookup;

