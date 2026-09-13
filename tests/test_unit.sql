-- ============================================================================
-- OSM-POIS DuckDB Unit Tests & Linter
-- Verifies:
--   1. Taxonomy integrity (no orphaned categories, valid hierarchies)
--   2. Category resolution logic against mock test cases
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Part 1: Taxonomy & Mapping Integrity Checks
-- ----------------------------------------------------------------------------

-- Check 1.1: Load taxonomy and mapping rules
CREATE TEMP TABLE overture_taxonomy AS
SELECT 
    trim(column0) AS overture_cat,
    str_split(replace(replace(trim(column1), '[', ''), ']', ''), ',') AS hierarchy
FROM read_csv('mappings/overture_categories.csv', header=False);

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
FROM read_csv('mappings/overture_to_osm_categories.csv', header=False);

-- Check 1.2: Assert no orphaned target categories
CREATE TEMP TABLE orphaned_categories AS
SELECT DISTINCT r.overture_cat
FROM category_rules r
LEFT JOIN overture_taxonomy t ON r.overture_cat = t.overture_cat
WHERE r.overture_cat IS NOT NULL 
  AND r.overture_cat != ''
  AND t.overture_cat IS NULL;

SELECT 
    CASE 
        WHEN count(*) > 0 THEN error('TAXONOMY INTEGRITY FAILED: ' || count(*) || ' categories in overture_to_osm_categories.csv do not exist in overture_categories.csv!')
        ELSE '[OK] Taxonomy integrity check passed: 0 orphaned categories'
    END AS taxonomy_check
FROM orphaned_categories;

-- Check 1.3: Assert no empty taxonomy entries
CREATE TEMP TABLE empty_taxonomy_entries AS
SELECT column0, column1
FROM read_csv('mappings/overture_categories.csv', header=False)
WHERE column0 IS NULL OR trim(column0) = '' OR column1 IS NULL OR trim(column1) = '';

SELECT 
    CASE 
        WHEN count(*) > 0 THEN error('TAXONOMY INTEGRITY FAILED: Found empty rows in overture_categories.csv!')
        ELSE '[OK] Taxonomy format check passed: 0 empty rows'
    END AS empty_row_check
FROM empty_taxonomy_entries;

-- ----------------------------------------------------------------------------
-- Part 2: Mock Category Resolution Unit Tests
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE primary_rules AS
SELECT DISTINCT ON (primary_key, primary_val)
    overture_cat,
    primary_key,
    primary_val
FROM category_rules
ORDER BY primary_key, primary_val, has_subtag ASC, overture_cat ASC;

CREATE TEMP TABLE test_cases (
    test_id VARCHAR,
    expected_category VARCHAR,
    amenity VARCHAR DEFAULT NULL,
    cuisine VARCHAR DEFAULT NULL,
    shop VARCHAR DEFAULT NULL,
    tourism VARCHAR DEFAULT NULL,
    leisure VARCHAR DEFAULT NULL,
    office VARCHAR DEFAULT NULL,
    craft VARCHAR DEFAULT NULL,
    healthcare VARCHAR DEFAULT NULL,
    historic VARCHAR DEFAULT NULL,
    sport VARCHAR DEFAULT NULL,
    aeroway VARCHAR DEFAULT NULL,
    railway VARCHAR DEFAULT NULL,
    station VARCHAR DEFAULT NULL,
    religion VARCHAR DEFAULT NULL,
    denomination VARCHAR DEFAULT NULL
);

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC01-Doctor-General', 'doctors_office', 'doctors'),
    ('TC02-Dentist', 'dentist', 'dentist'),
    ('TC03-Pharmacy', 'pharmacy', 'pharmacy'),
    ('TC04-Hospital', 'hospital', 'hospital');

INSERT INTO test_cases (test_id, expected_category, shop) VALUES
    ('TC05-Hairdresser-General', 'hair_salon', 'hairdresser'),
    ('TC06-Beauty-Salon', 'beauty_salon', 'beauty'),
    ('TC07-Bakery', 'bakery', 'bakery'),
    ('TC08-Supermarket', 'supermarket', 'supermarket'),
    ('TC09-Clothing', 'clothing_store', 'clothes'),
    ('TC10-Convenience-Store', 'convenience_store', 'convenience');

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC11-Restaurant-Generic', 'restaurant', 'restaurant'),
    ('TC12-Cafe', 'cafe', 'cafe'),
    ('TC13-Fast-Food', 'fast_food_restaurant', 'fast_food'),
    ('TC14-Pub', 'pub', 'pub'),
    ('TC15-Beer-Garden', 'beer_garden', 'beer_garden');

INSERT INTO test_cases (test_id, expected_category, amenity, cuisine) VALUES
    ('TC16-Restaurant-Italian', 'italian_restaurant', 'restaurant', 'italian'),
    ('TC17-Restaurant-German-Multi', 'german_restaurant', 'restaurant', 'german;regional');

INSERT INTO test_cases (test_id, expected_category, amenity, religion, denomination) VALUES
    ('TC18-Catholic-Church', 'catholic_church', 'place_of_worship', 'christian', 'catholic'),
    ('TC19-Roman-Catholic', 'catholic_church', 'place_of_worship', 'christian', 'roman_catholic'),
    ('TC20-Evangelical-Church', 'evangelical_church', 'place_of_worship', 'christian', 'evangelical'),
    ('TC21-Lutheran-Protestant', 'evangelical_church', 'place_of_worship', 'christian', 'lutheran'),
    ('TC22-Protestant', 'evangelical_church', 'place_of_worship', 'christian', 'protestant');

INSERT INTO test_cases (test_id, expected_category, amenity, religion) VALUES
    ('TC23-Christian-Cathedral', 'church_cathedral', 'place_of_worship', 'christian'),
    ('TC24-Mosque', 'mosque', 'place_of_worship', 'muslim'),
    ('TC25-Synagogue', 'synagogue', 'place_of_worship', 'jewish');

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC26-Worship-Fallback', 'religious_destination', 'place_of_worship'),
    ('TC27-EV-Charging', 'ev_charging_station', 'charging_station'),
    ('TC28-Post-Box', 'post_box', 'post_box'),
    ('TC29-Recycling', 'recycling_center', 'recycling');

INSERT INTO test_cases (test_id, expected_category, railway) VALUES
    ('TC30-Train-Station', 'train_station', 'station');

INSERT INTO test_cases (test_id, expected_category, railway, station) VALUES
    ('TC31-Subway-Station', 'light_rail_and_subway_station', 'station', 'subway');

INSERT INTO test_cases (test_id, expected_category, historic) VALUES
    ('TC32-Memorial', 'sculpture_statue', 'memorial');

INSERT INTO test_cases (test_id, expected_category) VALUES
    ('TC33-Fallback-POI', 'point_of_interest');

CREATE TEMP TABLE evaluated AS
SELECT 
    t.test_id,
    t.expected_category,
    COALESCE(
        -- 1. Cuisine-specific restaurant match
        CASE WHEN t.amenity = 'restaurant' AND t.cuisine IS NOT NULL THEN
            (SELECT r.overture_cat FROM category_rules r 
             WHERE r.primary_key = 'amenity' AND r.primary_val = 'restaurant' 
               AND r.sub_key = 'cuisine' AND r.sub_val = split_part(t.cuisine, ';', 1) 
             ORDER BY r.overture_cat ASC
             LIMIT 1)
        END,
        -- 2. Transit station subtag match
        CASE WHEN t.railway = 'station' AND t.station IS NOT NULL THEN
            (SELECT r.overture_cat FROM category_rules r 
             WHERE r.primary_key = 'railway' AND r.primary_val = 'station' 
               AND r.sub_key = 'station' AND r.sub_val = t.station 
             ORDER BY r.overture_cat ASC
             LIMIT 1)
        END,
        -- 3. Place of worship denomination & religion subtag match
        CASE WHEN t.amenity = 'place_of_worship' THEN
            COALESCE(
                CASE WHEN t.religion IS NOT NULL AND t.denomination IS NOT NULL THEN
                    (SELECT r.overture_cat FROM category_rules r 
                     WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                       AND r.sub_key = 'religion' AND r.sub_val = split_part(t.religion, ';', 1)
                       AND r.sub3_key = 'denomination' AND r.sub3_val = split_part(t.denomination, ';', 1)
                     ORDER BY r.overture_cat ASC
                     LIMIT 1)
                END,
                CASE WHEN t.denomination IS NOT NULL THEN
                    (SELECT r.overture_cat FROM category_rules r 
                     WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                       AND (
                           (r.sub_key = 'denomination' AND r.sub_val = split_part(t.denomination, ';', 1)) OR
                           (r.sub3_key = 'denomination' AND r.sub3_val = split_part(t.denomination, ';', 1))
                       )
                     ORDER BY r.overture_cat ASC
                     LIMIT 1)
                END,
                CASE WHEN t.religion IS NOT NULL THEN
                    (SELECT r.overture_cat FROM category_rules r 
                     WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                       AND r.sub_key = 'religion' AND r.sub_val = split_part(t.religion, ';', 1)
                       AND (r.sub3_key IS NULL OR r.sub3_key = '')
                     ORDER BY r.overture_cat ASC
                     LIMIT 1)
                END
            )
        END,
        -- 4. Primary tag matches from deterministic rule table
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'amenity' AND r.primary_val = t.amenity),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'shop' AND r.primary_val = t.shop),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'tourism' AND r.primary_val = t.tourism),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'leisure' AND r.primary_val = t.leisure),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'office' AND r.primary_val = t.office),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'craft' AND r.primary_val = t.craft),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'healthcare' AND r.primary_val = t.healthcare),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'historic' AND r.primary_val = t.historic),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'railway' AND r.primary_val = t.railway),
        (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'aeroway' AND r.primary_val = t.aeroway),
        t.amenity,
        t.shop,
        t.tourism,
        t.leisure,
        'point_of_interest'
    ) AS actual_category
FROM test_cases t;

-- Print detailed result table
SELECT 
    test_id,
    expected_category,
    actual_category,
    CASE WHEN expected_category = actual_category THEN 'PASS' ELSE 'FAIL' END AS status
FROM evaluated
ORDER BY test_id;

-- Hard assertion: fail if any test failed
SELECT 
    CASE 
        WHEN count(*) > 0 THEN error('UNIT TEST FAILED: ' || count(*) || ' test cases did not match expected categories!')
        ELSE '[OK] All ' || (SELECT count(*) FROM evaluated) || ' category mapping unit tests passed successfully!'
    END AS unit_test_assertion
FROM evaluated
WHERE expected_category != actual_category;

-- ----------------------------------------------------------------------------
-- Part 3: Schema Types, Multilingual Extraction & Micro-Infrastructure Tests
-- ----------------------------------------------------------------------------

-- Check 3.1: Multilingual extraction & namespace filtering logic
CREATE TEMP TABLE mock_names_input AS
SELECT 
    '{"@type":"node","@id":123,"name":"Hauptbahnhof","name:en":"Main Station","name:de":"Hauptbahnhof","name:fr":"Gare Centrale","alt_name":"Hbf","int_name":"Central Station","name:etymology:wikidata":"Q123","name:signed":"no","name:empty":""}'::JSON AS properties;

CREATE TEMP TABLE mock_names_result AS
WITH extracted AS (
    SELECT 
        [
            k for k in json_keys(properties)
            if (
                (
                    k LIKE 'name:%'
                    AND k NOT LIKE 'name:%:%'
                    AND substring(k, 6) NOT IN ('etymology', 'source', 'botanical', 'prefix', 'genitive', 'left', 'right', 'signed')
                )
                OR k IN ('alt_name', 'int_name')
            )
            AND json_extract_string(properties, '$."' || k || '"') != ''
        ] AS name_keys,
        properties
    FROM mock_names_input
)
SELECT 
    CAST(
        map(
            [CASE WHEN k LIKE 'name:%' THEN substring(k, 6) ELSE k END for k in name_keys],
            [json_extract_string(properties, '$."' || k || '"') for k in name_keys]
        ) AS MAP(VARCHAR, VARCHAR)
    ) AS names_common
FROM extracted;

SELECT 
    CASE 
        WHEN names_common['en'] = 'Main Station'
         AND names_common['de'] = 'Hauptbahnhof'
         AND names_common['fr'] = 'Gare Centrale'
         AND names_common['alt_name'] = 'Hbf'
         AND names_common['int_name'] = 'Central Station'
         AND names_common['etymology:wikidata'] IS NULL
         AND names_common['signed'] IS NULL
         AND names_common['empty'] IS NULL
         AND cardinality(names_common) = 5
        THEN '[OK] Multilingual name extraction test passed: 5 languages mapped, namespaces excluded'
        ELSE error('MULTILINGUAL EXTRACTION FAILED: unexpected map content!')
    END AS multilingual_check
FROM mock_names_result;

-- Check 3.2: Micro-infrastructure filtering logic (benches/waste baskets dropped, post boxes kept)
CREATE TEMP TABLE mock_micro_input AS
SELECT 1 AS id, '{"amenity":"bench","operator":"City"}'::JSON AS properties
UNION ALL
SELECT 2 AS id, '{"amenity":"waste_basket","operator":"BSR"}'::JSON AS properties
UNION ALL
SELECT 3 AS id, '{"amenity":"shelter","operator":"DB"}'::JSON AS properties
UNION ALL
SELECT 4 AS id, '{"amenity":"post_box","operator":"La Poste"}'::JSON AS properties
UNION ALL
SELECT 5 AS id, '{"amenity":"bench","shop":"bakery","name":"Boulangerie"}'::JSON AS properties;

CREATE TEMP TABLE mock_micro_filtered AS
SELECT 
    id,
    COALESCE(json_extract_string(properties, '$.name'), json_extract_string(properties, '$.brand'), json_extract_string(properties, '$.operator'), CASE WHEN json_extract_string(properties, '$.amenity') = 'post_box' THEN 'Post Box' ELSE NULL END) AS name,
    json_extract_string(properties, '$.amenity') AS amenity,
    json_extract_string(properties, '$.shop') AS shop
FROM mock_micro_input
WHERE (json_extract_string(properties, '$.name') IS NOT NULL 
       OR json_extract_string(properties, '$.brand') IS NOT NULL 
       OR json_extract_string(properties, '$.operator') IS NOT NULL
       OR json_extract_string(properties, '$.amenity') = 'post_box')
  AND (json_extract_string(properties, '$.amenity') IS NOT NULL 
       OR json_extract_string(properties, '$.shop') IS NOT NULL)
  AND (
      json_extract_string(properties, '$.amenity') IS NULL 
      OR json_extract_string(properties, '$.amenity') NOT IN ('bench', 'waste_basket', 'shelter', 'grit_bin', 'hunting_stand', 'feeding_place', 'waste_disposal', 'ticket_validator')
      OR json_extract_string(properties, '$.shop') IS NOT NULL
  );

SELECT 
    CASE 
        WHEN list_sort(list(id)) = [4, 5]
        THEN '[OK] Micro-infrastructure filter passed: benches/waste baskets excluded, post boxes preserved'
        ELSE error('MICRO-INFRASTRUCTURE FILTER FAILED: unexpected IDs retained!')
    END AS micro_filter_check
FROM mock_micro_filtered;

-- Check 3.3: Schema type definitions check (rules struct array, common map)
CREATE TEMP TABLE schema_type_check AS
SELECT 
    CAST(NULL AS STRUCT(
        variant VARCHAR, 
        "language" VARCHAR, 
        perspectives STRUCT("mode" VARCHAR, countries VARCHAR[]), 
        "value" VARCHAR, 
        "between" DOUBLE[], 
        side VARCHAR
    )[]) AS rules_col,
    CAST(map(['en'], ['Test']) AS MAP(VARCHAR, VARCHAR)) AS common_col;

SELECT 
    CASE 
        WHEN typeof(rules_col) = 'STRUCT(variant VARCHAR, "language" VARCHAR, perspectives STRUCT("mode" VARCHAR, countries VARCHAR[]), "value" VARCHAR, "between" DOUBLE[], side VARCHAR)[]'
         AND typeof(common_col) = 'MAP(VARCHAR, VARCHAR)'
        THEN '[OK] Overture places schema types verified: rules is STRUCT[], common is MAP(VARCHAR, VARCHAR)'
        ELSE error('SCHEMA TYPE CHECK FAILED!')
    END AS schema_types_check
FROM schema_type_check;
