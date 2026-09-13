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
