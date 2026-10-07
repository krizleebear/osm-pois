-- 06_places_transform.sql - Places Export Transform View (Single Source of Truth)
-- Defines places_export: full projection, categorization, confidence, relation membership
-- and access type resolution for the final Overture Places-compatible GeoParquet.
-- Consumed by the final COPY in scripts/export_pois.sql (CLI/FIFO streaming path)
-- and by the Python streaming driver via 'INSERT INTO stage SELECT * FROM places_export'
-- (chunked BytesIO path).
CREATE OR REPLACE TEMP VIEW places_export AS
    WITH base_json AS (
        SELECT 
            ST_GeomFromGeoJSON(geometry) AS geom,
            properties
        FROM osm_json_src
        WHERE (
            is_poi_candidate(properties)
            OR (
                properties['building'] IN ('office', 'school', 'kindergarten', 'college', 'university', 'hospital', 'civic', 'government', 'fire_station', 'train_station', 'transportation', 'hotel', 'sports_hall', 'stadium', 'retail', 'commercial', 'industrial', 'warehouse')
                AND properties['name'] IS NOT NULL
            )
        )
        AND geometry IS NOT NULL
    ),
    valid_geoms AS (
        SELECT 
            geom,
            properties
        FROM base_json
        WHERE geom IS NOT NULL
          AND ST_IsValid(geom)
          AND is_poi_candidate(properties, ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON'))
    ),
    raw_features AS (
        SELECT 
            'osm:' || properties['@type'] || '/' || properties['@id'] AS id,
            TRY_CAST(properties['@version'] AS INTEGER) AS osm_version,
            CASE 
                WHEN properties['@timestamp'] IS NOT NULL 
                THEN strftime(to_timestamp(TRY_CAST(properties['@timestamp'] AS BIGINT)), '%Y-%m-%dT%H:%M:%SZ') 
                ELSE NULL 
            END AS osm_timestamp,
            resolve_poi_name(properties) AS name,
            osm_names_common(properties) AS names_common,
            osm_names_rules(properties) AS names_rules,
            osm_brand_common(properties) AS brand_common,
            COALESCE(
                properties['amenity'],
                properties['disused:amenity'],
                properties['construction:amenity']
            ) AS amenity,
            properties['religion'] AS religion,
            properties['denomination'] AS denomination,
            properties['cuisine'] AS cuisine,
            properties['shop'] AS shop,
            COALESCE(
                properties['tourism'],
                properties['disused:tourism'],
                properties['construction:tourism']
            ) AS tourism,
            properties['information'] AS information,
            properties['entrance'] AS entrance,
            COALESCE(
                properties['leisure'],
                properties['disused:leisure'],
                properties['construction:leisure']
            ) AS leisure,
            properties['office'] AS office,
            properties['building'] AS building,
            properties['craft'] AS craft,
            properties['healthcare'] AS healthcare,
            properties['historic'] AS historic,
            properties['sport'] AS sport,
            properties['landuse'] AS landuse,
            COALESCE(
                properties['aeroway'],
                properties['disused:aeroway'],
                properties['construction:aeroway']
            ) AS aeroway,
            COALESCE(
                properties['railway'],
                properties['disused:railway'],
                properties['construction:railway']
            ) AS railway,
            properties['station'] AS station,
            properties['man_made'] AS man_made,
            properties['emergency'] AS emergency,
            properties['highway'] AS highway,
            properties['operator'] AS operator,
            properties['ref'] AS ref,
            properties['brand'] AS brand,
            properties['brand:wikidata'] AS brand_wikidata,
            properties['addr:street'] AS addr_street,
            properties['addr:housenumber'] AS addr_housenumber,
            properties['addr:postcode'] AS addr_postcode,
            properties['addr:city'] AS addr_city,
            COALESCE(properties['website'], properties['contact:website']) AS website,
            COALESCE(properties['phone'], properties['contact:phone']) AS phone,
            COALESCE(properties['email'], properties['contact:email']) AS email,
            extract_socials(properties) AS socials,
            -- Extended operational attributes (Superset extension)
            properties['opening_hours'] AS opening_hours,
            properties['wheelchair'] AS wheelchair,
            extract_payment_methods(properties) AS payment_methods,
            extract_poi_level(properties) AS level,
            properties['delivery'] AS delivery,
            properties['takeaway'] AS takeaway,
            is_temporary_closed_landmark(properties, ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON')) AS is_temp_closed,
            resolve_lifecycle_state(properties) AS lifecycle_state,
            osm_raw_tags(properties) AS tags,
            -- Metric footprint area (m², integer) of polygon/multipolygon POI geometries;
            -- NULL for point/node features (see osm_area_sqm in 02_macros.sql)
            osm_area_sqm(geom) AS area_m2,
            -- Upstream POI confidence scoring
            calculate_poi_confidence(
                properties,
                ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON'),
                TRY_CAST(properties['@version'] AS INTEGER),
                CASE 
                    WHEN properties['@timestamp'] IS NOT NULL 
                    THEN strftime(to_timestamp(TRY_CAST(properties['@timestamp'] AS BIGINT)), '%Y-%m-%dT%H:%M:%SZ') 
                    ELSE NULL 
                END,
                COALESCE(properties['website'], properties['contact:website']) IS NOT NULL,
                COALESCE(properties['phone'], properties['contact:phone']) IS NOT NULL
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
                f.highway, f.landuse,
                f.sport, f.building
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
                c.cuisine, c.sport, c.landuse, c.building
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
        format_address(addr_street, addr_housenumber, addr_city, addr_postcode, getvariable('country_code')) AS addresses,
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
        CASE 
            WHEN is_temp_closed THEN 'temporarily_unavailable'
            ELSE 'active'
        END AS operating_status,
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
        lifecycle_state,
        CASE WHEN is_temp_closed THEN true ELSE NULL END AS navigation_relevant,
        tags,
        -- Parent & Relation Membership Attributes (Superset Extension)
        parent_osm_id,
        parent_feature_kind,
        relation_id,
        member_role,
        access_type
    FROM with_relations c
;
