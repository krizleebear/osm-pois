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
                json_extract_string(properties, '$.building') IN ('office', 'school', 'kindergarten', 'college', 'university', 'hospital', 'civic', 'government', 'fire_station', 'train_station', 'transportation', 'hotel', 'sports_hall', 'stadium', 'retail', 'commercial', 'industrial', 'warehouse')
                AND json_extract_string(properties, '$.name') IS NOT NULL
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
            'osm:' || json_extract_string(properties, '$.@type') || '/' || json_extract_string(properties, '$.@id') AS id,
            TRY_CAST(json_extract_string(properties, '$.@version') AS INTEGER) AS osm_version,
            CASE 
                WHEN json_extract_string(properties, '$.@timestamp') IS NOT NULL 
                THEN strftime(to_timestamp(TRY_CAST(json_extract_string(properties, '$.@timestamp') AS BIGINT)), '%Y-%m-%dT%H:%M:%SZ') 
                ELSE NULL 
            END AS osm_timestamp,
            resolve_poi_name(properties) AS name,
            osm_names_common(properties) AS names_common,
            osm_names_rules(properties) AS names_rules,
            osm_brand_common(properties) AS brand_common,
            COALESCE(
                json_extract_string(properties, '$.amenity'),
                json_extract_string(properties, '$."disused:amenity"'),
                json_extract_string(properties, '$."construction:amenity"')
            ) AS amenity,
            json_extract_string(properties, '$.religion') AS religion,
            json_extract_string(properties, '$.denomination') AS denomination,
            json_extract_string(properties, '$.cuisine') AS cuisine,
            json_extract_string(properties, '$.shop') AS shop,
            COALESCE(
                json_extract_string(properties, '$.tourism'),
                json_extract_string(properties, '$."disused:tourism"'),
                json_extract_string(properties, '$."construction:tourism"')
            ) AS tourism,
            json_extract_string(properties, '$.information') AS information,
            json_extract_string(properties, '$.entrance') AS entrance,
            COALESCE(
                json_extract_string(properties, '$.leisure'),
                json_extract_string(properties, '$."disused:leisure"'),
                json_extract_string(properties, '$."construction:leisure"')
            ) AS leisure,
            json_extract_string(properties, '$.office') AS office,
            json_extract_string(properties, '$.building') AS building,
            json_extract_string(properties, '$.craft') AS craft,
            json_extract_string(properties, '$.healthcare') AS healthcare,
            json_extract_string(properties, '$.historic') AS historic,
            json_extract_string(properties, '$.sport') AS sport,
            json_extract_string(properties, '$.landuse') AS landuse,
            COALESCE(
                json_extract_string(properties, '$.aeroway'),
                json_extract_string(properties, '$."disused:aeroway"'),
                json_extract_string(properties, '$."construction:aeroway"')
            ) AS aeroway,
            COALESCE(
                json_extract_string(properties, '$.railway'),
                json_extract_string(properties, '$."disused:railway"'),
                json_extract_string(properties, '$."construction:railway"')
            ) AS railway,
            json_extract_string(properties, '$.station') AS station,
            json_extract_string(properties, '$.man_made') AS man_made,
            json_extract_string(properties, '$.emergency') AS emergency,
            json_extract_string(properties, '$.highway') AS highway,
            json_extract_string(properties, '$.operator') AS operator,
            json_extract_string(properties, '$.ref') AS ref,
            json_extract_string(properties, '$.brand') AS brand,
            json_extract_string(properties, '$.brand:wikidata') AS brand_wikidata,
            json_extract_string(properties, '$.addr:street') AS addr_street,
            json_extract_string(properties, '$.addr:housenumber') AS addr_housenumber,
            json_extract_string(properties, '$.addr:postcode') AS addr_postcode,
            json_extract_string(properties, '$.addr:city') AS addr_city,
            COALESCE(json_extract_string(properties, '$.website'), json_extract_string(properties, '$.contact:website')) AS website,
            COALESCE(json_extract_string(properties, '$.phone'), json_extract_string(properties, '$.contact:phone')) AS phone,
            COALESCE(json_extract_string(properties, '$.email'), json_extract_string(properties, '$.contact:email')) AS email,
            extract_socials(properties) AS socials,
            -- Extended operational attributes (Superset extension)
            json_extract_string(properties, '$.opening_hours') AS opening_hours,
            json_extract_string(properties, '$.wheelchair') AS wheelchair,
            extract_payment_methods(properties) AS payment_methods,
            extract_poi_level(properties) AS level,
            json_extract_string(properties, '$.delivery') AS delivery,
            json_extract_string(properties, '$.takeaway') AS takeaway,
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
