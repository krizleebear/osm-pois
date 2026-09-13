-- 03_categorization.sql — Single Source of Truth for POI Category Resolution
-- Resolves Overture primary category from OSM primary and secondary tags.

CREATE OR REPLACE MACRO resolve_poi_category(
    p_amenity, p_shop, p_tourism, p_leisure, p_office,
    p_craft, p_healthcare, p_historic, p_railway, p_aeroway,
    p_cuisine, p_station, p_religion, p_denomination,
    p_information := NULL, p_name := NULL
) AS
COALESCE(
    -- 1. Cuisine-specific restaurant match (e.g. amenity=restaurant,cuisine=italian -> italian_restaurant)
    CASE WHEN p_amenity = 'restaurant' AND p_cuisine IS NOT NULL THEN
        (SELECT r.overture_cat FROM category_rules r 
         WHERE r.primary_key = 'amenity' AND r.primary_val = 'restaurant' 
           AND r.sub_key = 'cuisine' AND r.sub_val = split_part(p_cuisine, ';', 1) 
         ORDER BY r.overture_cat ASC
         LIMIT 1)
    END,
    -- 2. Transit station subtag match (e.g. railway=station,station=subway -> light_rail_and_subway_station)
    CASE WHEN p_railway = 'station' AND p_station IS NOT NULL THEN
        (SELECT r.overture_cat FROM category_rules r 
         WHERE r.primary_key = 'railway' AND r.primary_val = 'station' 
           AND r.sub_key = 'station' AND r.sub_val = p_station 
         ORDER BY r.overture_cat ASC
         LIMIT 1)
    END,
    -- 3. Place of worship denomination & religion subtag match (e.g. amenity=place_of_worship,religion=christian,denomination=catholic -> catholic_church)
    CASE WHEN p_amenity = 'place_of_worship' THEN
        COALESCE(
            -- 3-tag match: amenity=place_of_worship, religion=..., denomination=...
            CASE WHEN p_religion IS NOT NULL AND p_denomination IS NOT NULL THEN
                (SELECT r.overture_cat FROM category_rules r 
                 WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                   AND r.sub_key = 'religion' AND r.sub_val = split_part(p_religion, ';', 1)
                   AND r.sub3_key = 'denomination' AND r.sub3_val = split_part(p_denomination, ';', 1)
                 ORDER BY r.overture_cat ASC
                 LIMIT 1)
            END,
            -- 2-tag match by denomination: amenity=place_of_worship, denomination=...
            CASE WHEN p_denomination IS NOT NULL THEN
                (SELECT r.overture_cat FROM category_rules r 
                 WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                   AND (
                       (r.sub_key = 'denomination' AND r.sub_val = split_part(p_denomination, ';', 1)) OR
                       (r.sub3_key = 'denomination' AND r.sub3_val = split_part(p_denomination, ';', 1))
                   )
                 ORDER BY r.overture_cat ASC
                 LIMIT 1)
            END,
            -- 2-tag match by religion: amenity=place_of_worship, religion=...
            CASE WHEN p_religion IS NOT NULL THEN
                (SELECT r.overture_cat FROM category_rules r 
                 WHERE r.primary_key = 'amenity' AND r.primary_val = 'place_of_worship' 
                   AND r.sub_key = 'religion' AND r.sub_val = split_part(p_religion, ';', 1)
                   AND (r.sub3_key IS NULL OR r.sub3_key = '')
                 ORDER BY r.overture_cat ASC
                 LIMIT 1)
            END
        )
    END,
    -- 4. Primary tag matches from deterministic rule table
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'amenity' AND r.primary_val = p_amenity),
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'shop' AND r.primary_val = p_shop),
    -- Tourism resolution: resolve information subtags specially, else query primary_rules
    CASE 
        WHEN p_tourism = 'information' THEN
            CASE 
                WHEN p_information IN ('office', 'visitor_centre', 'visitor_center') THEN 'visitor_center'
                WHEN p_information IS NULL AND (
                    lower(p_name) LIKE '%office du tourisme%'
                    OR lower(p_name) LIKE '%tourist%info%'
                    OR lower(p_name) LIKE '%fremdenverkehr%'
                    OR lower(p_name) LIKE '%visitor%cent%'
                    OR lower(p_name) LIKE '%syndicat d''initiative%'
                ) THEN 'visitor_center'
                WHEN p_information IS NOT NULL THEN p_information
                ELSE NULL
            END
        ELSE (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'tourism' AND r.primary_val = p_tourism)
    END,
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'leisure' AND r.primary_val = p_leisure),
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'office' AND r.primary_val = p_office),
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'craft' AND r.primary_val = p_craft),
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'healthcare' AND r.primary_val = p_healthcare),
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'historic' AND r.primary_val = p_historic),
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'railway' AND r.primary_val = p_railway),
    (SELECT r.overture_cat FROM primary_rules r WHERE r.primary_key = 'aeroway' AND r.primary_val = p_aeroway),
    p_amenity,
    p_shop,
    CASE WHEN p_tourism = 'information' THEN p_information ELSE p_tourism END,
    p_leisure,
    'point_of_interest'
);
