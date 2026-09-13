-- ============================================================================
-- OSM-POIS DuckDB Unit Tests & Linter
-- Verifies:
--   1. Taxonomy integrity (no orphaned categories, valid hierarchies)
--   2. Category resolution logic against mock test cases (Single Source of Truth)
--   3. Reusable DuckDB macros (Multilingual names, Micro-infrastructure, Schema)
-- ============================================================================

-- Load modular SQL components (Single Source of Truth)
.read scripts/sql/01_taxonomy.sql
.read scripts/sql/02_macros.sql
.read scripts/sql/03_categorization.sql

-- ----------------------------------------------------------------------------
-- Part 1: Taxonomy & Mapping Integrity Checks
-- ----------------------------------------------------------------------------

-- Check 1.1: Assert no orphaned target categories
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

-- Check 1.2: Assert no empty taxonomy entries
CREATE TEMP TABLE empty_taxonomy_entries AS
SELECT column0, column1
FROM read_csv(COALESCE(getvariable('repo_root'), '.') || '/mappings/overture_categories.csv', header=False)
WHERE column0 IS NULL OR trim(column0) = '' OR column1 IS NULL OR trim(column1) = '';

SELECT 
    CASE 
        WHEN count(*) > 0 THEN error('TAXONOMY INTEGRITY FAILED: Found empty rows in overture_categories.csv!')
        ELSE '[OK] Taxonomy format check passed: 0 empty rows'
    END AS empty_row_check
FROM empty_taxonomy_entries;

-- ----------------------------------------------------------------------------
-- Part 2: Mock Category Resolution Unit Tests (via resolve_poi_category macro)
-- ----------------------------------------------------------------------------

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
    denomination VARCHAR DEFAULT NULL,
    information VARCHAR DEFAULT NULL,
    name VARCHAR DEFAULT NULL
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

INSERT INTO test_cases (test_id, expected_category, tourism, information) VALUES
    ('TC34-Tourist-Info-Office', 'visitor_center', 'information', 'office'),
    ('TC35-Visitor-Centre', 'visitor_center', 'information', 'visitor_centre'),
    ('TC36-Visitor-Center-US', 'visitor_center', 'information', 'visitor_center'),
    ('TC37-Info-Board-Not-Center', 'board', 'information', 'board'),
    ('TC38-Info-Map-Not-Center', 'map', 'information', 'map');

INSERT INTO test_cases (test_id, expected_category, tourism, name) VALUES
    ('TC39-Tourist-Office-No-Subtag', 'visitor_center', 'information', 'Office du Tourisme');

-- Evaluate categories using the production resolve_poi_category macro
CREATE TEMP TABLE evaluated AS
SELECT 
    t.test_id,
    t.expected_category,
    resolve_poi_category(
        t.amenity, t.shop, t.tourism, t.leisure, t.office,
        t.craft, t.healthcare, t.historic, t.railway, t.aeroway,
        t.cuisine, t.station, t.religion, t.denomination,
        t.information, t.name
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

-- Check 3.1: Multilingual extraction & namespace filtering logic via osm_names_common macro
CREATE TEMP TABLE mock_names_input AS
SELECT 
    '{"@type":"node","@id":123,"name":"Hauptbahnhof","name:en":"Main Station","name:de":"Hauptbahnhof","name:fr":"Gare Centrale","alt_name":"Hbf","int_name":"Central Station","name:etymology:wikidata":"Q123","name:signed":"no","name:empty":""}'::JSON AS properties;

CREATE TEMP TABLE mock_names_result AS
SELECT osm_names_common(properties) AS names_common
FROM mock_names_input;

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

-- Check 3.2: Micro-infrastructure filtering logic via is_poi_candidate macro
CREATE TEMP TABLE mock_micro_input AS
SELECT 1 AS id, '{"amenity":"bench","operator":"City"}'::JSON AS properties
UNION ALL
SELECT 2 AS id, '{"amenity":"waste_basket","operator":"BSR"}'::JSON AS properties
UNION ALL
SELECT 3 AS id, '{"amenity":"shelter","operator":"DB"}'::JSON AS properties
UNION ALL
SELECT 4 AS id, '{"amenity":"post_box","operator":"La Poste"}'::JSON AS properties
UNION ALL
SELECT 5 AS id, '{"amenity":"bench","shop":"bakery","name":"Boulangerie"}'::JSON AS properties
UNION ALL
SELECT 6 AS id, '{"tourism":"information","information":"board","name":"Wanderweg Tafel"}'::JSON AS properties
UNION ALL
SELECT 7 AS id, '{"tourism":"information","information":"guidepost","operator":"Schwarzwaldverein"}'::JSON AS properties
UNION ALL
SELECT 8 AS id, '{"tourism":"information","information":"map","name":"Stadtplan"}'::JSON AS properties
UNION ALL
SELECT 9 AS id, '{"tourism":"information","information":"office","name":"Tourist Information"}'::JSON AS properties
UNION ALL
SELECT 10 AS id, '{"tourism":"information","name":"Office du Tourisme"}'::JSON AS properties;

CREATE TEMP TABLE mock_micro_filtered AS
SELECT id, resolve_poi_name(properties) AS name
FROM mock_micro_input
WHERE is_poi_candidate(properties);

SELECT 
    CASE 
        WHEN list_sort(list(id)) = [4, 5, 9, 10]
        THEN '[OK] Micro-infrastructure filter passed: benches, waste baskets, and info boards/maps excluded, real POIs preserved'
        ELSE error('MICRO-INFRASTRUCTURE FILTER FAILED: unexpected IDs retained!')
    END AS micro_filter_check
FROM mock_micro_filtered;

-- Check 3.3: Schema type definitions check via empty_rules macro
CREATE TEMP TABLE schema_type_check AS
SELECT 
    empty_rules() AS rules_col,
    CAST(map(['en'], ['Test']) AS MAP(VARCHAR, VARCHAR)) AS common_col;

SELECT 
    CASE 
        WHEN typeof(rules_col) = 'STRUCT(variant VARCHAR, "language" VARCHAR, perspectives STRUCT("mode" VARCHAR, countries VARCHAR[]), "value" VARCHAR, "between" DOUBLE[], side VARCHAR)[]'
         AND typeof(common_col) = 'MAP(VARCHAR, VARCHAR)'
        THEN '[OK] Overture places schema types verified: rules is STRUCT[], common is MAP(VARCHAR, VARCHAR)'
        ELSE error('SCHEMA TYPE CHECK FAILED!')
    END AS schema_types_check
FROM schema_type_check;
