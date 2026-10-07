-- ============================================================================
-- OSM-POIS DuckDB Unit Tests & Linter
-- Verifies:
--   1. Taxonomy integrity (no orphaned categories, valid hierarchies)
--   2. Category resolution logic against mock test cases (Single Source of Truth)
--   3. Reusable DuckDB macros (Multilingual names, Micro-infrastructure, Schema)
-- ============================================================================

-- Hermetic spatial init: the macros under test (osm_area_sqm and the mock geometry
-- fixtures) rely on ST_Transform / ST_Area / ST_GeomFromText. Production matches this
-- via `LOAD spatial;` at the top of scripts/export_pois.sql; the unit suite must do the
-- same so results do not depend on what a user's $HOME/.duckdbrc happens to pre-load
-- (CI runs as root without a .duckdbrc). Idempotent: no-op if already loaded.
LOAD spatial;

-- Load modular SQL components (Single Source of Truth)
.read scripts/sql/01_taxonomy.sql
.read scripts/sql/02_macros.sql
.read scripts/sql/03_categorization.sql
.read scripts/sql/04_confidence.sql
.read scripts/sql/05_relations.sql

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

-- Check 1.3: Assert no duplicate lines in overture_to_osm_categories.csv
CREATE TEMP TABLE duplicate_osm_mapping_lines AS
SELECT 
    column0 AS overture_cat, 
    column1 AS osm_rule, 
    count(*) AS occurrences
FROM read_csv(COALESCE(getvariable('repo_root'), '.') || '/mappings/overture_to_osm_categories.csv', header=False)
GROUP BY column0, column1
HAVING count(*) > 1;

SELECT 
    CASE 
        WHEN count(*) > 0 THEN error('TAXONOMY INTEGRITY FAILED: ' || count(*) || ' duplicate line(s) found in overture_to_osm_categories.csv!')
        ELSE '[OK] Taxonomy duplicate check passed: 0 duplicate lines in overture_to_osm_categories.csv'
    END AS duplicate_mapping_check
FROM duplicate_osm_mapping_lines;

-- Check 1.4: Assert no duplicate categories in overture_categories.csv
CREATE TEMP TABLE duplicate_taxonomy_categories AS
SELECT 
    column0 AS overture_cat,
    count(*) AS occurrences
FROM read_csv(COALESCE(getvariable('repo_root'), '.') || '/mappings/overture_categories.csv', header=False)
GROUP BY column0
HAVING count(*) > 1;

SELECT 
    CASE 
        WHEN count(*) > 0 THEN error('TAXONOMY INTEGRITY FAILED: ' || count(*) || ' duplicate category definition(s) found in overture_categories.csv!')
        ELSE '[OK] Taxonomy duplicate check passed: 0 duplicate categories in overture_categories.csv'
    END AS duplicate_taxonomy_check
FROM duplicate_taxonomy_categories;

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
    name VARCHAR DEFAULT NULL,
    man_made VARCHAR DEFAULT NULL,
    emergency VARCHAR DEFAULT NULL,
    highway VARCHAR DEFAULT NULL,
    landuse VARCHAR DEFAULT NULL,
    building VARCHAR DEFAULT NULL
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

INSERT INTO test_cases (test_id, expected_category, emergency) VALUES
    ('TC40-Defibrillator', 'defibrillator', 'defibrillator');

INSERT INTO test_cases (test_id, expected_category, man_made) VALUES
    ('TC41-Man-Made-Tower', 'historic_tower', 'tower'),
    ('TC42-Man-Made-Lighthouse', 'lighthouse', 'lighthouse'),
    ('TC43-Man-Made-Water-Tower', 'water_tower', 'water_tower'),
    ('TC44-Man-Made-Windmill', 'windmill', 'windmill');

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC45-Toilets', 'public_restrooms', 'toilets'),
    ('TC46-Parking', 'parking', 'parking'),
    ('TC47-ATM', 'atms', 'atm'),
    ('TC48-Parcel-Locker', 'package_locker', 'parcel_locker'),
    ('TC49-Taxi', 'taxi_service', 'taxi');

INSERT INTO test_cases (test_id, expected_category, highway) VALUES
    ('TC50-Highway-Rest-Area', 'rest_areas', 'rest_area'),
    ('TC51-Highway-Services', 'rest_areas', 'services');

INSERT INTO test_cases (test_id, expected_category, landuse) VALUES
    ('TC52-Cemetery', 'cemeteries', 'cemetery'),
    ('TC53-Winter-Sports', 'ski_area', 'winter_sports');

INSERT INTO test_cases (test_id, expected_category, craft) VALUES
    ('TC54-Craft-Metal-Construction', 'metal_fabricator', 'metal_construction'),
    ('TC55-Craft-HVAC', 'hvac_service', 'hvac'),
    ('TC56-Craft-Joiner', 'carpenter', 'joiner');

INSERT INTO test_cases (test_id, expected_category, office) VALUES
    ('TC57-Office-Notary', 'notary_public', 'notary'),
    ('TC58-Office-Coworking', 'coworking_space', 'coworking');

INSERT INTO test_cases (test_id, expected_category, healthcare) VALUES
    ('TC59-Healthcare-Occupational-Therapy', 'occupational_therapy', 'occupational_therapist'),
    ('TC60-Healthcare-Centre', 'community_health_center', 'centre');

INSERT INTO test_cases (test_id, expected_category, leisure, sport) VALUES
    ('TC61-Pitch-Soccer', 'soccer_field', 'pitch', 'soccer'),
    ('TC62-Pitch-Tennis', 'tennis_court', 'pitch', 'tennis'),
    ('TC63-Pitch-Generic', 'sport_field', 'pitch', NULL),
    ('TC64-Sports-Centre-Swimming', 'swimming_pool', 'sports_centre', 'swimming'),
    ('TC65-Sports-Centre-Generic', 'sports_complex', 'sports_centre', NULL);

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC66-Vending-Machine', 'vending_machine', 'vending_machine');

INSERT INTO test_cases (test_id, expected_category, man_made) VALUES
    ('TC67-Works-Industrial', 'b2b_industrial_and_machine_service', 'works');

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC68-University-General', 'college_university', 'university'),
    ('TC69-Studio-General', 'recording_and_rehearsal_studio', 'studio'),
    ('TC70-Training-General', 'specialty_school', 'training');

INSERT INTO test_cases (test_id, expected_category, shop) VALUES
    ('TC71-Dry-Cleaning', 'dry_cleaning', 'dry_cleaning'),
    ('TC72-Trade-Wholesale', 'wholesaler', 'trade');

INSERT INTO test_cases (test_id, expected_category, leisure) VALUES
    ('TC73-Garden-General', 'garden', 'garden'),
    ('TC74-Sports-Hall', 'sport_or_fitness_facility', 'sports_hall');

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC75-Graveyard', 'cemetery', 'grave_yard');

INSERT INTO test_cases (test_id, expected_category, office) VALUES
    ('TC76-Office-Research', 'research_institute', 'research');

INSERT INTO test_cases (test_id, expected_category, landuse) VALUES
    ('TC77-Landuse-Industrial', 'b2b_industrial_and_machine_service', 'industrial');

INSERT INTO test_cases (test_id, expected_category, healthcare) VALUES
    ('TC78-Healthcare-Doctor', 'doctors_office', 'doctor'),
    ('TC79-Healthcare-Dentist', 'dentist', 'dentist'),
    ('TC80-Healthcare-Clinic', 'outpatient_care_facility', 'clinic');

INSERT INTO test_cases (test_id, expected_category, craft) VALUES
    ('TC81-Craft-Printer', 'printing_service', 'printer'),
    ('TC84-Craft-Tailor', 'tailor', 'tailor'),
    ('TC92-Craft-Upholsterer', 'furniture_reupholstery', 'upholsterer');

INSERT INTO test_cases (test_id, expected_category, amenity) VALUES
    ('TC82-Bus-Station', 'bus_station', 'bus_station'),
    ('TC88-Amenity-CampSite', 'campground', 'camp_site'),
    ('TC89-Amenity-Dojo', 'martial_arts_club', 'dojo'),
    ('TC94-Amenity-Brothel', 'adult_entertainment_venue', 'brothel');

INSERT INTO test_cases (test_id, expected_category, office) VALUES
    ('TC83-Office-Association', 'civic_organization', 'association');

INSERT INTO test_cases (test_id, expected_category, tourism) VALUES
    ('TC85-Tourism-Artwork', 'sculpture_statue', 'artwork'),
    ('TC99-Tourism-Tours', 'tour_operator', 'tours');

INSERT INTO test_cases (test_id, expected_category, leisure, sport) VALUES
    ('TC86-Leisure-Track-Athletics', 'track_and_field_track', 'track', 'athletics'),
    ('TC87-Leisure-Track-Running', 'running_and_track', 'track', 'running');

INSERT INTO test_cases (test_id, expected_category, leisure) VALUES
    ('TC95-Leisure-Club', 'social_club', 'club'),
    ('TC96-Leisure-Dance', 'dance_club', 'dance');

INSERT INTO test_cases (test_id, expected_category, healthcare) VALUES
    ('TC90-Healthcare-Rehab', 'rehabilitation_center', 'rehabilitation'),
    ('TC91-Healthcare-Counseling', 'counseling', 'counselling');

INSERT INTO test_cases (test_id, expected_category, man_made) VALUES
    ('TC93-ManMade-Monitoring', 'monitoring_station', 'monitoring_station');

INSERT INTO test_cases (test_id, expected_category, shop) VALUES
    ('TC97-Shop-Food', 'grocery_store', 'food'),
    ('TC98-Shop-General', 'convenience_store', 'general');

INSERT INTO test_cases (test_id, expected_category, building) VALUES
    ('TC102-Building-Office', 'corporate_or_business_office', 'office'),
    ('TC103-Building-School', 'school', 'school'),
    ('TC104-Building-Warehouse-Fallback', 'point_of_interest', 'warehouse');

-- Evaluate categories using the production resolve_poi_category macro
CREATE TEMP TABLE evaluated AS
SELECT 
    t.test_id,
    t.expected_category,
    resolve_poi_category(
        t.amenity, t.shop, t.tourism, t.leisure, t.office,
        t.craft, t.healthcare, t.historic, t.railway, t.aeroway,
        t.cuisine, t.station, t.religion, t.denomination,
        t.information, t.name,
        t.man_made, t.emergency,
        t.highway, t.landuse,
        t.sport, t.building
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
SELECT 10 AS id, '{"tourism":"information","name":"Office du Tourisme"}'::JSON AS properties
UNION ALL
SELECT 11 AS id, '{"amenity":"post_box"}'::JSON AS properties
UNION ALL
SELECT 12 AS id, '{"leisure":"playground","access":"yes"}'::JSON AS properties
UNION ALL
SELECT 13 AS id, '{"amenity":"toilets","wheelchair":"yes"}'::JSON AS properties
UNION ALL
SELECT 14 AS id, '{"amenity":"charging_station","capacity":"4"}'::JSON AS properties
UNION ALL
SELECT 15 AS id, '{"amenity":"parking","parking":"surface"}'::JSON AS properties
UNION ALL
SELECT 16 AS id, '{"emergency":"defibrillator"}'::JSON AS properties
UNION ALL
SELECT 17 AS id, '{"amenity":"parcel_locker","brand":"DHL","ref":"102"}'::JSON AS properties
UNION ALL
SELECT 18 AS id, '{"amenity":"parcel_locker","ref":"102"}'::JSON AS properties
UNION ALL
SELECT 19 AS id, '{"man_made":"tower","name":"Fernsehturm"}'::JSON AS properties
UNION ALL
SELECT 20 AS id, '{"man_made":"flagpole"}'::JSON AS properties
UNION ALL
SELECT 21 AS id, '{"man_made":"surveillance","name":"Cam 1"}'::JSON AS properties
UNION ALL
SELECT 22 AS id, '{"man_made":"water_tower","name":"Wasserturm"}'::JSON AS properties
UNION ALL
SELECT 23 AS id, '{"amenity":"drinking_water"}'::JSON AS properties
UNION ALL
SELECT 24 AS id, '{"amenity":"atm"}'::JSON AS properties
UNION ALL
SELECT 25 AS id, '{"amenity":"taxi"}'::JSON AS properties
UNION ALL
SELECT 26 AS id, '{"highway":"rest_area"}'::JSON AS properties
UNION ALL
SELECT 27 AS id, '{"highway":"services","name":"Rasthof Holmmoor"}'::JSON AS properties;

CREATE TEMP TABLE mock_micro_filtered AS
SELECT id, resolve_poi_name(properties) AS name
FROM mock_micro_input
WHERE is_poi_candidate(properties);

SELECT 
    CASE 
        WHEN list_sort(list(id)) = [4, 5, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 22, 23, 24, 25, 26, 27]
             AND (SELECT count(*) FROM mock_micro_filtered WHERE id IN (4, 11, 12, 13, 14, 15, 16, 18, 23, 24, 25, 26) AND name IS NULL) = 12
             AND (SELECT count(*) FROM mock_micro_filtered WHERE id IN (5, 9, 10, 17, 19, 22, 27) AND name IS NOT NULL) = 7
        THEN '[OK] Micro-infrastructure & utility filter passed: unnamed utility POIs admitted with NULL name, operator decoupled, and named man_made landmarks retained'
        ELSE error('MICRO-INFRASTRUCTURE FILTER FAILED: unexpected IDs or names retained!')
    END AS micro_filter_check
FROM mock_micro_filtered;

-- Check 3.2b: Temporary closed landmark filtering and lifecycle state (Issue #1)
CREATE TEMP TABLE mock_lifecycle_input AS
SELECT 101 AS id, '{"@type":"way","disused:amenity":"theatre","name":"Theater Augsburg","wikidata":"Q15850550","building":"yes"}'::JSON AS props, TRUE AS is_area -- Theater Augsburg under renovation
UNION ALL
SELECT 102 AS id, '{"@type":"relation","construction:amenity":"hospital","name":"Neues Klinikum","operator":"Städtisches Klinikum","building":"yes"}'::JSON AS props, TRUE AS is_area -- Hospital under construction
UNION ALL
SELECT 103 AS id, '{"@type":"way","amenity":"museum","name":"Stadtmuseum","temporary:closure":"renovation","addr:street":"Museumsweg","building":"yes"}'::JSON AS props, TRUE AS is_area -- Museum temporarily closed
UNION ALL
SELECT 104 AS id, '{"@type":"node","disused:shop":"bakery","name":"Alte Bäckerei"}'::JSON AS props, FALSE AS is_area -- Disused shop (must be excluded)
UNION ALL
SELECT 105 AS id, '{"@type":"way","disused:amenity":"theatre","name":"Altes Theater","demolished:building":"yes"}'::JSON AS props, TRUE AS is_area -- Demolished (must be excluded)
UNION ALL
SELECT 106 AS id, '{"@type":"way","disused:amenity":"theatre","name":"Ruine Theater","ruins":"yes"}'::JSON AS props, TRUE AS is_area -- Ruins (must be excluded)
UNION ALL
SELECT 107 AS id, '{"@type":"node","disused:amenity":"bench","name":"Alte Bank"}'::JSON AS props, FALSE AS is_area; -- Micro-infra (must be excluded)

CREATE TEMP TABLE mock_lifecycle_evaluated AS
SELECT 
    id,
    is_poi_candidate(props, is_area) AS is_candidate,
    is_temporary_closed_landmark(props, is_area) AS is_temp_closed,
    resolve_lifecycle_state(props) AS lifecycle_state
FROM mock_lifecycle_input;

SELECT 
    CASE 
        WHEN (SELECT list_sort(list(id)) FROM mock_lifecycle_evaluated WHERE is_candidate) = [101, 102, 103]
         AND (SELECT list_sort(list(id)) FROM mock_lifecycle_evaluated WHERE is_temp_closed) = [101, 102, 103]
         AND (SELECT lifecycle_state FROM mock_lifecycle_evaluated WHERE id = 101) = 'renovation'
         AND (SELECT lifecycle_state FROM mock_lifecycle_evaluated WHERE id = 102) = 'reconstruction'
         AND (SELECT lifecycle_state FROM mock_lifecycle_evaluated WHERE id = 103) = 'temporary_closure'
        THEN '[OK] Temporary closed landmark check passed: Augsburg Theater, Klinikum, and Stadtmuseum admitted with lifecycle states; disused shops and demolished buildings rejected'
        ELSE error('LIFECYCLE LANDMARK CHECK FAILED: unexpected filtering or lifecycle states!')
    END AS lifecycle_check
FROM mock_lifecycle_evaluated
LIMIT 1;

-- Check 3.2c: Named search-relevant area classification & exclusions (Issue #2)
CREATE TEMP TABLE mock_area_poi_input AS
SELECT 201 AS id, '{"@type":"way","name":"Englischer Garten","leisure":"park"}'::JSON AS props, TRUE AS is_area -- Named park area
UNION ALL
SELECT 202 AS id, '{"@type":"way","name":"Nordfriedhof","landuse":"cemetery"}'::JSON AS props, TRUE AS is_area -- Named cemetery area
UNION ALL
SELECT 203 AS id, '{"@type":"relation","name":"Campus Garching","amenity":"university"}'::JSON AS props, TRUE AS is_area -- Named university campus
UNION ALL
SELECT 204 AS id, '{"@type":"way","name":"Kleingartenverein Frohsinn","landuse":"allotments"}'::JSON AS props, TRUE AS is_area -- Named allotments
UNION ALL
SELECT 205 AS id, '{"@type":"way","name":"Wohngebiet Nord","landuse":"residential"}'::JSON AS props, TRUE AS is_area -- Technical residential (must be excluded)
UNION ALL
SELECT 206 AS id, '{"@type":"way","name":"Gewerbegebiet Süd","landuse":"industrial"}'::JSON AS props, TRUE AS is_area -- Technical industrial (must be excluded)
UNION ALL
SELECT 207 AS id, '{"@type":"way","landuse":"cemetery"}'::JSON AS props, TRUE AS is_area -- Unnamed cemetery area (must be excluded from area extraction)
UNION ALL
SELECT 208 AS id, '{"@type":"way","name":"Acker 12","landuse":"farmland"}'::JSON AS props, TRUE AS is_area; -- Technical farmland (must be excluded)

CREATE TEMP TABLE mock_area_poi_evaluated AS
SELECT 
    id,
    is_poi_candidate(props, is_area) AS is_candidate,
    is_search_relevant_area(props, is_area) AS is_search_area
FROM mock_area_poi_input;

SELECT 
    CASE 
        WHEN (SELECT list_sort(list(id)) FROM mock_area_poi_evaluated WHERE is_candidate) = [201, 202, 203, 204]
         AND (SELECT list_sort(list(id)) FROM mock_area_poi_evaluated WHERE is_search_area) = [201, 202, 203, 204]
        THEN '[OK] Search-relevant area check passed: Englischer Garten, Nordfriedhof, Campus, and Allotments admitted; residential/industrial/farmland and unnamed areas excluded'
        ELSE error('SEARCH-RELEVANT AREA CHECK FAILED: unexpected area POI retention!')
    END AS area_poi_check
FROM mock_area_poi_evaluated
LIMIT 1;

-- Check 3.2d: Named functional building fallback (Issue #3)
CREATE TEMP TABLE mock_functional_building_input AS
SELECT 301 AS id, '{"@type":"way","building":"office","name":"e.solutions","addr:street":"Frauenweiherstraße","addr:housenumber":"17","addr:city":"Erlangen","website":"https://www.esolutions.de"}'::JSON AS props, TRUE AS is_area
UNION ALL
SELECT 302 AS id, '{"@type":"way","building":"school","name":"Apian-Gymnasium Ingolstadt","addr:street":"Maximilianstraße","addr:housenumber":"25","addr:city":"Ingolstadt","contact:website":"http://www.apian.de"}'::JSON AS props, TRUE AS is_area
UNION ALL
SELECT 303 AS id, '{"@type":"way","building":"warehouse","name":"Logistics Hub","website":"https://example.test"}'::JSON AS props, TRUE AS is_area
UNION ALL
SELECT 304 AS id, '{"@type":"way","building":"residential","name":"Wohnhaus Nord","addr:street":"Hauptstraße"}'::JSON AS props, TRUE AS is_area
UNION ALL
SELECT 305 AS id, '{"@type":"way","building":"office","name":"Anonymous Office"}'::JSON AS props, TRUE AS is_area
UNION ALL
SELECT 306 AS id, '{"@type":"node","building":"school","name":"Point School","website":"https://example.test"}'::JSON AS props, FALSE AS is_area
UNION ALL
SELECT 307 AS id, '{"@type":"way","building":"school","name":"Apian-Gymnasium Ingolstadt"}'::JSON AS props, TRUE AS is_area; -- Public school without verification fields (must be admitted)

CREATE TEMP TABLE mock_functional_building_evaluated AS
SELECT
    id,
    is_poi_candidate(props, is_area) AS is_candidate,
    is_named_functional_building(props, is_area) AS is_functional_building
FROM mock_functional_building_input;

SELECT
    CASE
        WHEN (SELECT list_sort(list(id)) FROM mock_functional_building_evaluated WHERE is_candidate) = [301, 302, 303, 307]
         AND (SELECT list_sort(list(id)) FROM mock_functional_building_evaluated WHERE is_functional_building) = [301, 302, 303, 307]
        THEN '[OK] Functional building fallback passed: verified office, school, and warehouse areas admitted; residential, unverified, and point features excluded'
        ELSE error('FUNCTIONAL BUILDING FILTER FAILED: unexpected building POI retention!')
    END AS functional_building_check
FROM mock_functional_building_evaluated
LIMIT 1;

-- Check 3.2e: Deduplication test of equivalent node and way representations (Issue #2 item 4)
CREATE TEMP TABLE mock_dedup_input AS
SELECT 'osm:way/1001' AS id, 'Central Park' AS name, 'park' AS main_category, 7.4121 AS lon, 43.7121 AS lat, 0.85::DOUBLE AS confidence, 3 AS osm_version
UNION ALL
SELECT 'osm:node/2001' AS id, 'Central Park' AS name, 'park' AS main_category, 7.4123 AS lon, 43.7122 AS lat, 0.60::DOUBLE AS confidence, 1 AS osm_version
UNION ALL
SELECT 'osm:node/3001' AS id, 'Other Park' AS name, 'park' AS main_category, 7.4200 AS lon, 43.7200 AS lat, 0.70::DOUBLE AS confidence, 1 AS osm_version;

CREATE TEMP TABLE mock_dedup_result AS
SELECT * EXCLUDE (dedup_rank)
FROM (
    SELECT 
        *,
        ROW_NUMBER() OVER (
            PARTITION BY 
                CASE 
                    WHEN name IS NOT NULL AND name != '' AND main_category IS NOT NULL
                    THEN lower(trim(name)) || '|' || main_category || '|' || CAST(round(lon, 3) AS VARCHAR) || '|' || CAST(round(lat, 3) AS VARCHAR)
                    ELSE id 
                END
            ORDER BY 
                CASE 
                    WHEN id LIKE 'osm:relation/%' THEN 1
                    WHEN id LIKE 'osm:way/%' THEN 2
                    ELSE 3
                END,
                confidence DESC,
                COALESCE(osm_version, 1) DESC
        ) AS dedup_rank
    FROM mock_dedup_input
)
WHERE dedup_rank = 1;

SELECT 
    CASE 
        WHEN list_sort(list(id)) = ['osm:node/3001', 'osm:way/1001']
        THEN '[OK] Deduplication test passed: redundant node/2001 dropped in favor of way/1001 for Central Park'
        ELSE error('DEDUPLICATION TEST FAILED: unexpected features retained ' || CAST(list(id) AS VARCHAR))
    END AS dedup_check
FROM mock_dedup_result;

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

-- Check 3.4: Alternative names rules extraction (osm_names_rules)
CREATE TEMP TABLE mock_rules_test AS
SELECT 
    osm_names_rules('{"name":"Hauptbahnhof","alt_name":"Hbf","official_name":"Zentralbahnhof","short_name:de":"Hb","loc_name":"Bahnhof","reg_name":"Grossbahnhof","int_name":"Central Station","nickname":"Stachus","nickname:en":"The Gherkin"}'::JSON) AS rules_populated,
    osm_names_rules('{"name":"Bäckerei"}'::JSON) AS rules_empty;

SELECT 
    CASE 
        WHEN typeof(rules_populated) = 'STRUCT(variant VARCHAR, "language" VARCHAR, perspectives STRUCT("mode" VARCHAR, countries VARCHAR[]), "value" VARCHAR, "between" DOUBLE[], side VARCHAR)[]'
         AND typeof(rules_empty) = 'STRUCT(variant VARCHAR, "language" VARCHAR, perspectives STRUCT("mode" VARCHAR, countries VARCHAR[]), "value" VARCHAR, "between" DOUBLE[], side VARCHAR)[]'
         AND len(rules_populated) = 8
         AND rules_empty IS NULL
         AND [r.variant for r in rules_populated if r.value = 'Hbf'][1] = 'alternate'
         AND [r.variant for r in rules_populated if r.value = 'Zentralbahnhof'][1] = 'official'
         AND [r.variant for r in rules_populated if r.value = 'Central Station'][1] = 'international'
         AND [r.language for r in rules_populated if r.value = 'Hb'][1] = 'de'
         AND [r.variant for r in rules_populated if r.value = 'Stachus'][1] = 'alternate'
         AND [r.language for r in rules_populated if r.value = 'Stachus'][1] IS NULL
         AND [r.variant for r in rules_populated if r.value = 'The Gherkin'][1] = 'alternate'
         AND [r.language for r in rules_populated if r.value = 'The Gherkin'][1] = 'en'
        THEN '[OK] Alternative name rules extraction test passed: all variants, nicknames & languages mapped'
        ELSE error('NAME RULES EXTRACTION FAILED!')
    END AS names_rules_check
FROM mock_rules_test;

-- Check 3.5: Socials extraction (extract_socials)
CREATE TEMP TABLE mock_socials_test AS
SELECT 
    extract_socials('{"name":"Shop","contact:facebook":"myshopfb","instagram":"https://instagram.com/myshop","contact:twitter":"@myshoptw","contact:linkedin":"company/myshop"}'::JSON) AS socials_populated,
    extract_socials('{"name":"Shop"}'::JSON) AS socials_empty;

SELECT 
    CASE 
        WHEN list_sort(socials_populated) = [
            'https://instagram.com/myshop',
            'https://www.facebook.com/myshopfb',
            'https://www.linkedin.com/company/myshop',
            'https://x.com/myshoptw'
        ]
        AND socials_empty = CAST([] AS VARCHAR[])
        THEN '[OK] Socials extraction test passed: handles normalized, full URLs preserved, empty list returned when absent'
        ELSE error('SOCIALS EXTRACTION FAILED!')
    END AS socials_check
FROM mock_socials_test;

-- Check 3.6: Alternate categories resolution (resolve_alternate_categories)
CREATE TEMP TABLE mock_alternate_cat_test AS
SELECT 
    resolve_alternate_categories(
        'cafe',
        'cafe', 'bakery', NULL, NULL, NULL,
        NULL, NULL, NULL, NULL,
        NULL, NULL
    ) AS bakery_cafe,
    resolve_alternate_categories(
        'italian_restaurant',
        'restaurant', NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL,
        'pizza;italian', NULL
    ) AS pizza_italian,
    resolve_alternate_categories(
        'sports_complex',
        NULL, NULL, NULL, 'sports_centre', NULL,
        NULL, NULL, NULL, NULL,
        NULL, 'swimming;fitness'
    ) AS sports_centre,
    resolve_alternate_categories(
        'restaurant',
        'restaurant', NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL,
        NULL, NULL
    ) AS plain_restaurant;

SELECT 
    CASE 
        WHEN bakery_cafe = ['bakery']
         AND list_sort(pizza_italian) = ['italian', 'pizza', 'pizza_delivery_service', 'restaurant']
         AND list_sort(sports_centre) = ['fitness', 'sports_centre', 'swimming']
         AND plain_restaurant = CAST([] AS VARCHAR[])
        THEN '[OK] Alternate categories resolution passed: secondary place tags, cuisines, and sports extracted'
        ELSE error('ALTERNATE CATEGORIES RESOLUTION FAILED!')
    END AS alternate_cat_check
FROM mock_alternate_cat_test;

-- Check 3.7: Metric footprint area macro (osm_area_sqm)
-- Globally valid equal-area EASE-Grid 2.0 / WGS84 projection (EPSG:6933); integer m²; NULL for
-- point / non-area geometries. Cross-validates both the type contract and the numeric magnitude.
CREATE TEMP TABLE mock_area_test AS
SELECT
    osm_area_sqm(ST_GeomFromText('POLYGON((7.409 43.707, 7.421 43.707, 7.421 43.715, 7.409 43.715, 7.409 43.707))')) AS area_monaco_poly,
    osm_area_sqm(ST_GeomFromText('POINT(7.41 43.71)')) AS area_point,
    osm_area_sqm(ST_GeomFromText('LINESTRING(7.40 43.70, 7.42 43.72)')) AS area_line,
    osm_area_sqm(NULL) AS area_null,
    osm_area_sqm(ST_GeomFromText('MULTIPOLYGON(((7.409 43.707, 7.421 43.707, 7.421 43.715, 7.409 43.715, 7.409 43.707)))')) AS area_multi;

SELECT
    CASE
        WHEN typeof(area_monaco_poly) = 'BIGINT'
         AND area_monaco_poly BETWEEN 700000 AND 1100000
         AND area_point IS NULL
         AND area_line IS NULL
         AND area_null IS NULL
         AND typeof(area_multi) = 'BIGINT'
         AND area_multi = area_monaco_poly
        THEN '[OK] osm_area_sqm: EPSG:6933 equal-area integer m² for polygon/multipolygon, NULL for point/line/NULL'
        ELSE error('OSM AREA MACRO TEST FAILED!')
    END AS area_sqm_check
FROM mock_area_test;

-- ----------------------------------------------------------------------------
-- Part 4: POI Confidence Scoring & Operational Tag Extractions
-- ----------------------------------------------------------------------------

-- Check 4.1: Dynamic Payment Methods Extraction & Sorting
CREATE TEMP TABLE mock_payment_test AS
SELECT extract_payment_methods('{"payment:cash":"yes","payment:credit_cards":"yes","payment:apple_pay":"only","payment:bitcoin":"no","payment:notes":"yes"}'::JSON) AS payment_methods;

SELECT 
    CASE 
        WHEN payment_methods = ['apple_pay', 'cash', 'credit_cards', 'notes']
        THEN '[OK] Payment methods extraction passed: filtered yes/only and sorted alphabetically'
        ELSE error('PAYMENT METHODS EXTRACTION FAILED: unexpected array ' || CAST(payment_methods AS VARCHAR))
    END AS payment_methods_check
FROM mock_payment_test;

-- Check 4.2: POI Confidence Scoring Calibration Test Cases
CREATE TEMP TABLE confidence_test_cases (
    test_id VARCHAR,
    expected_score DECIMAL(11,2),
    props JSON,
    is_polygon BOOLEAN,
    osm_version INTEGER,
    osm_timestamp VARCHAR,
    has_website BOOLEAN,
    has_phone BOOLEAN,
    ref_year INTEGER
);

INSERT INTO confidence_test_cases VALUES
    -- Base Minimal node: 0.60 - 0.08 (minimal penalty) = 0.52
    ('CONF-01-Minimal', 0.52, '{"name":"Minimal POI","amenity":"restaurant"}'::JSON, false, 1, '2026-01-01T00:00:00Z', false, false, 2026),
    
    -- Standard Venue with Website (contact bonus +0.08): 0.60 + 0.08 = 0.68
    ('CONF-02-WithContact', 0.68, '{"name":"Standard Venue","amenity":"restaurant","website":"https://example.com"}'::JSON, false, 1, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Fresh Survey (+0.15 survey + 0.08 contact): 0.60 + 0.15 + 0.08 = 0.83
    ('CONF-03-FreshSurvey', 0.83, '{"name":"Surveyed Place","amenity":"restaurant","check_date":"2025-06-15"}'::JSON, false, 1, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Older Survey (+0.08 older survey + 0.08 contact): 0.60 + 0.08 + 0.08 = 0.76
    ('CONF-04-OlderSurvey', 0.76, '{"name":"Older Survey Place","amenity":"restaurant","survey:date":"2022-03-10"}'::JSON, false, 1, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Opening Hours (+0.10 hours + 0.08 contact): 0.60 + 0.10 + 0.08 = 0.78
    ('CONF-05-OpeningHours', 0.78, '{"name":"Cafe","amenity":"cafe","opening_hours":"Mo-Fr 08:00-18:00"}'::JSON, false, 1, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Entity Wikidata (+0.06 wiki + 0.08 contact): 0.60 + 0.06 + 0.08 = 0.74
    ('CONF-06-Wikidata', 0.74, '{"name":"Museum","tourism":"museum","wikidata":"Q12345"}'::JSON, false, 1, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Tag Richness (+0.05 richness + 0.08 contact): 0.60 + 0.05 + 0.08 = 0.73
    ('CONF-07-TagRichness', 0.73, '{"name":"Bistro","amenity":"restaurant","wheelchair":"yes","cuisine":"french"}'::JSON, false, 1, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Building Anchor (+0.05 building + 0.08 contact): 0.60 + 0.05 + 0.08 = 0.73
    ('CONF-08-BuildingAnchor', 0.73, '{"name":"Store","shop":"supermarket"}'::JSON, true, 1, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Mature Revision (+0.03 version + 0.08 contact): 0.60 + 0.03 + 0.08 = 0.71
    ('CONF-09-MatureRevision', 0.71, '{"name":"Shop","shop":"clothes"}'::JSON, false, 4, '2026-01-01T00:00:00Z', true, false, 2026),
    
    -- Top-Tier Venue (all bonuses sum to 0.52, capped at +0.39): 0.60 + 0.39 = 0.99
    ('CONF-10-TopTierMax', 0.99, '{"name":"Grand Hotel","tourism":"hotel","check_date":"2025-05-01","opening_hours":"24/7","wikidata":"Q999","wheelchair":"yes","cuisine":"fine_dining","building":"hotel"}'::JSON, true, 5, '2025-05-01T12:00:00Z', true, true, 2026),
    
    -- Closure Note (-0.35 note - 0.08 minimal): 0.60 - 0.35 - 0.08 = 0.17
    ('CONF-11-ClosureNote', 0.17, '{"name":"Old Bar","amenity":"bar","note":"dauerhaft geschlossen"}'::JSON, false, 1, '2026-01-01T00:00:00Z', false, false, 2026),
    
    -- Lifecycle Disused (-0.40 disused - 0.08 minimal): 0.60 - 0.40 - 0.08 = 0.12
    ('CONF-12-LifecycleDisused', 0.12, '{"name":"Disused Bank","amenity":"bank","disused":"yes"}'::JSON, false, 1, '2026-01-01T00:00:00Z', false, false, 2026),
    
    -- Stale Record (> 8 years without contacts: -0.15 stale - 0.08 minimal): 0.60 - 0.15 - 0.08 = 0.37
    ('CONF-13-StaleRecord', 0.37, '{"name":"Stale Shop","shop":"books"}'::JSON, false, 1, '2015-05-01T00:00:00Z', false, false, 2026),
    
    -- Clamped Minimum (0.60 - 0.35 - 0.40 = -0.15 -> clamp to 0.10)
    ('CONF-14-ClampedMin', 0.10, '{"name":"Demolished Pub","amenity":"pub","disused:amenity":"pub","note":"abgerissen"}'::JSON, false, 1, '2026-01-01T00:00:00Z', false, false, 2026);

CREATE TEMP TABLE evaluated_confidence AS
SELECT 
    t.test_id,
    t.expected_score,
    calculate_poi_confidence(
        t.props,
        t.is_polygon,
        t.osm_version,
        t.osm_timestamp,
        t.has_website,
        t.has_phone,
        t.ref_year
    ) AS actual_score
FROM confidence_test_cases t;

SELECT 
    test_id,
    expected_score,
    actual_score,
    CASE WHEN expected_score = actual_score THEN 'PASS' ELSE 'FAIL' END AS status
FROM evaluated_confidence
ORDER BY test_id;

SELECT 
    CASE 
        WHEN count(*) > 0 THEN error('CONFIDENCE UNIT TEST FAILED: ' || count(*) || ' test cases did not match expected scores!')
        ELSE '[OK] All ' || (SELECT count(*) FROM evaluated_confidence) || ' confidence scoring unit tests passed successfully!'
    END AS confidence_unit_test_assertion
FROM evaluated_confidence
WHERE expected_score != actual_score;

-- Check 4.3: Generic Raw OSM Tags Extraction (osm_raw_tags)
CREATE TEMP TABLE mock_raw_tags_test AS
SELECT 
    osm_raw_tags('{"amenity":"charging_station","socket:type2":"yes","capacity":"4","payment:app":"yes","@id":"123","@type":"node","@version":"2","@timestamp":"1600000000"}'::JSON) AS tags_charging,
    osm_raw_tags('{"@id":"456","@type":"node","@version":"1"}'::JSON) AS tags_empty,
    osm_raw_tags('{"fixme:\"note\"":"check value","addr:street":"Rue de Lyon","@id":"789"}'::JSON) AS tags_special;

SELECT 
    CASE 
        WHEN typeof(tags_charging) = 'MAP(VARCHAR, VARCHAR)'
         AND tags_charging['socket:type2'] = 'yes'
         AND tags_charging['capacity'] = '4'
         AND tags_charging['payment:app'] = 'yes'
         AND tags_charging['amenity'] = 'charging_station'
         AND tags_charging['@id'] IS NULL
         AND tags_charging['@type'] IS NULL
         AND tags_charging['@version'] IS NULL
         AND cardinality(tags_charging) = 4
         AND tags_empty IS NULL
         AND typeof(tags_special) = 'MAP(VARCHAR, VARCHAR)'
         AND tags_special['fixme:"note"'] = 'check value'
         AND tags_special['addr:street'] = 'Rue de Lyon'
         AND cardinality(tags_special) = 2
        THEN '[OK] Generic raw tags extraction test passed: MAP(VARCHAR, VARCHAR) preserved, @-metadata excluded, NULL on tagless features'
        ELSE error('RAW TAGS EXTRACTION TEST FAILED!')
    END AS raw_tags_check
FROM mock_raw_tags_test;

-- Check 4.4: Access Type and Parent Relation Resolution (resolve_access_type)
CREATE TEMP TABLE mock_access_type_test AS
SELECT 
    resolve_access_type('parking_entrance', NULL, NULL, NULL, NULL) AS t_parking_entrance,
    resolve_access_type(NULL, NULL, 'subway_entrance', NULL, NULL) AS t_subway_entrance,
    resolve_access_type(NULL, 'main', NULL, NULL, NULL) AS t_entrance_main,
    resolve_access_type(NULL, 'delivery', NULL, NULL, NULL) AS t_entrance_delivery,
    resolve_access_type(NULL, 'emergency', NULL, NULL, NULL) AS t_entrance_emergency,
    resolve_access_type(NULL, NULL, NULL, 'entrance', 'parking') AS t_rel_parking_entrance,
    resolve_access_type(NULL, NULL, NULL, 'exit', 'parking') AS t_rel_parking_exit,
    resolve_access_type(NULL, NULL, NULL, 'entrance', 'hospital') AS t_rel_generic_access,
    resolve_access_type('restaurant', NULL, NULL, NULL, NULL) AS t_restaurant;

SELECT 
    CASE 
        WHEN t_parking_entrance = 'parking'
         AND t_subway_entrance = 'transit'
         AND t_entrance_main = 'pedestrian'
         AND t_entrance_delivery = 'delivery'
         AND t_entrance_emergency = 'emergency'
         AND t_rel_parking_entrance = 'parking'
         AND t_rel_parking_exit = 'parking'
         AND t_rel_generic_access = 'access'
         AND t_restaurant IS NULL
        THEN '[OK] Access type resolution test passed: parking, transit, pedestrian, delivery, emergency, and relation-derived access points resolved'
        ELSE error('ACCESS TYPE RESOLUTION TEST FAILED!')
    END AS access_type_check
FROM mock_access_type_test;


