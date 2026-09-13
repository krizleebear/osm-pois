-- 03_categorization.sql — Single Source of Truth for POI Category Resolution
-- Resolves Overture primary category from OSM primary and secondary tags.

CREATE OR REPLACE MACRO resolve_poi_category(
    p_amenity, p_shop, p_tourism, p_leisure, p_office,
    p_craft, p_healthcare, p_historic, p_railway, p_aeroway,
    p_cuisine, p_station, p_religion, p_denomination,
    p_information := NULL, p_name := NULL,
    p_man_made := NULL, p_emergency := NULL
) AS
COALESCE(
    -- 1. Cuisine-specific restaurant match (e.g. amenity=restaurant,cuisine=italian -> italian_restaurant)
    CASE WHEN p_amenity = 'restaurant' AND p_cuisine IS NOT NULL THEN
        (SELECT lookup FROM taxonomy_lookup).cuisine_map[split_part(p_cuisine, ';', 1)]
    END,
    -- 2. Transit station subtag match (e.g. railway=station,station=subway -> light_rail_and_subway_station)
    CASE WHEN p_railway = 'station' AND p_station IS NOT NULL THEN
        (SELECT lookup FROM taxonomy_lookup).station_map[p_station]
    END,
    -- 3. Place of worship denomination & religion subtag match (e.g. amenity=place_of_worship,religion=christian,denomination=catholic -> catholic_church)
    CASE WHEN p_amenity = 'place_of_worship' THEN
        COALESCE(
            -- 3-tag match: amenity=place_of_worship, religion=..., denomination=...
            CASE WHEN p_religion IS NOT NULL AND p_denomination IS NOT NULL THEN
                (SELECT lookup FROM taxonomy_lookup).worship_rel_denom_map[split_part(p_religion, ';', 1) || '=' || split_part(p_denomination, ';', 1)]
            END,
            -- 2-tag match by denomination: amenity=place_of_worship, denomination=...
            CASE WHEN p_denomination IS NOT NULL THEN
                (SELECT lookup FROM taxonomy_lookup).worship_denom_map[split_part(p_denomination, ';', 1)]
            END,
            -- 2-tag match by religion: amenity=place_of_worship, religion=...
            CASE WHEN p_religion IS NOT NULL THEN
                (SELECT lookup FROM taxonomy_lookup).worship_religion_map[split_part(p_religion, ';', 1)]
            END
        )
    END,
    -- 4. Primary tag matches from deterministic rule table
    (SELECT lookup FROM taxonomy_lookup).primary_map['amenity=' || p_amenity],
    (SELECT lookup FROM taxonomy_lookup).primary_map['shop=' || p_shop],
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
        ELSE (SELECT lookup FROM taxonomy_lookup).primary_map['tourism=' || p_tourism]
    END,
    (SELECT lookup FROM taxonomy_lookup).primary_map['leisure=' || p_leisure],
    (SELECT lookup FROM taxonomy_lookup).primary_map['office=' || p_office],
    (SELECT lookup FROM taxonomy_lookup).primary_map['craft=' || p_craft],
    (SELECT lookup FROM taxonomy_lookup).primary_map['healthcare=' || p_healthcare],
    (SELECT lookup FROM taxonomy_lookup).primary_map['historic=' || p_historic],
    (SELECT lookup FROM taxonomy_lookup).primary_map['railway=' || p_railway],
    (SELECT lookup FROM taxonomy_lookup).primary_map['aeroway=' || p_aeroway],
    (SELECT lookup FROM taxonomy_lookup).primary_map['man_made=' || p_man_made],
    (SELECT lookup FROM taxonomy_lookup).primary_map['emergency=' || p_emergency],
    p_amenity,
    p_shop,
    CASE WHEN p_tourism = 'information' THEN p_information ELSE p_tourism END,
    p_leisure,
    p_man_made,
    p_emergency,
    'point_of_interest'
);
