-- 03_categorization.sql — Single Source of Truth for POI Category Resolution
-- Resolves Overture primary category from OSM primary and secondary tags.

CREATE OR REPLACE MACRO resolve_poi_category(
    p_amenity, p_shop, p_tourism, p_leisure, p_office,
    p_craft, p_healthcare, p_historic, p_railway, p_aeroway,
    p_cuisine, p_station, p_religion, p_denomination,
    p_information := NULL, p_name := NULL,
    p_man_made := NULL, p_emergency := NULL,
    p_highway := NULL
) AS
COALESCE(
    -- 1. Cuisine-specific restaurant match (e.g. amenity=restaurant,cuisine=italian -> italian_restaurant)
    CASE WHEN p_amenity = 'restaurant' AND p_cuisine IS NOT NULL THEN
        getvariable('taxonomy_lookup').cuisine_map[split_part(p_cuisine, ';', 1)]
    END,
    -- 2. Transit station subtag match (e.g. railway=station,station=subway -> light_rail_and_subway_station)
    CASE WHEN p_railway = 'station' AND p_station IS NOT NULL THEN
        getvariable('taxonomy_lookup').station_map[p_station]
    END,
    -- 3. Place of worship denomination & religion subtag match (e.g. amenity=place_of_worship,religion=christian,denomination=catholic -> catholic_church)
    CASE WHEN p_amenity = 'place_of_worship' THEN
        COALESCE(
            -- 3-tag match: amenity=place_of_worship, religion=..., denomination=...
            CASE WHEN p_religion IS NOT NULL AND p_denomination IS NOT NULL THEN
                getvariable('taxonomy_lookup').worship_rel_denom_map[split_part(p_religion, ';', 1) || '=' || split_part(p_denomination, ';', 1)]
            END,
            -- 2-tag match by denomination: amenity=place_of_worship, denomination=...
            CASE WHEN p_denomination IS NOT NULL THEN
                getvariable('taxonomy_lookup').worship_denom_map[split_part(p_denomination, ';', 1)]
            END,
            -- 2-tag match by religion: amenity=place_of_worship, religion=...
            CASE WHEN p_religion IS NOT NULL THEN
                getvariable('taxonomy_lookup').worship_religion_map[split_part(p_religion, ';', 1)]
            END
        )
    END,
    -- 4. Primary tag matches from deterministic rule table
    getvariable('taxonomy_lookup').primary_map['amenity=' || p_amenity],
    getvariable('taxonomy_lookup').primary_map['shop=' || p_shop],
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
        ELSE getvariable('taxonomy_lookup').primary_map['tourism=' || p_tourism]
    END,
    getvariable('taxonomy_lookup').primary_map['leisure=' || p_leisure],
    getvariable('taxonomy_lookup').primary_map['office=' || p_office],
    getvariable('taxonomy_lookup').primary_map['craft=' || p_craft],
    getvariable('taxonomy_lookup').primary_map['healthcare=' || p_healthcare],
    getvariable('taxonomy_lookup').primary_map['historic=' || p_historic],
    getvariable('taxonomy_lookup').primary_map['railway=' || p_railway],
    getvariable('taxonomy_lookup').primary_map['aeroway=' || p_aeroway],
    getvariable('taxonomy_lookup').primary_map['highway=' || p_highway],
    getvariable('taxonomy_lookup').primary_map['man_made=' || p_man_made],
    getvariable('taxonomy_lookup').primary_map['emergency=' || p_emergency],
    p_amenity,
    p_shop,
    CASE WHEN p_tourism = 'information' THEN p_information ELSE p_tourism END,
    p_leisure,
    p_highway,
    p_man_made,
    p_emergency,
    'point_of_interest'
);

-- Single Source of Truth for Alternate Category Resolution
CREATE OR REPLACE MACRO resolve_alternate_categories(
    p_main_cat,
    p_amenity, p_shop, p_tourism, p_leisure, p_office,
    p_craft, p_healthcare, p_historic, p_highway,
    p_cuisine, p_sport
) AS
[
  x for x in list_distinct(
    list_concat(
      -- Mapped taxonomy categories of secondary tags
      [
        getvariable('taxonomy_lookup').primary_map['amenity=' || p_amenity],
        getvariable('taxonomy_lookup').primary_map['shop=' || p_shop],
        getvariable('taxonomy_lookup').primary_map['tourism=' || p_tourism],
        getvariable('taxonomy_lookup').primary_map['leisure=' || p_leisure],
        getvariable('taxonomy_lookup').primary_map['office=' || p_office],
        getvariable('taxonomy_lookup').primary_map['craft=' || p_craft],
        getvariable('taxonomy_lookup').primary_map['healthcare=' || p_healthcare],
        getvariable('taxonomy_lookup').primary_map['historic=' || p_historic],
        getvariable('taxonomy_lookup').primary_map['highway=' || p_highway],
        -- Mapped cuisine categories (up to 2 values)
        CASE WHEN p_cuisine IS NOT NULL THEN getvariable('taxonomy_lookup').cuisine_map[trim(split_part(p_cuisine, ';', 1))] END,
        CASE WHEN p_cuisine IS NOT NULL AND len(str_split(p_cuisine, ';')) >= 2 THEN getvariable('taxonomy_lookup').cuisine_map[trim(split_part(p_cuisine, ';', 2))] END,
        -- Raw place tags (if distinct from mapped)
        p_amenity,
        p_shop,
        p_tourism,
        p_leisure,
        p_office,
        p_craft,
        p_healthcare,
        p_historic,
        p_highway
      ],
      list_concat(
        -- Raw cuisine subtags
        CASE WHEN p_cuisine IS NOT NULL THEN [trim(c) for c in str_split(p_cuisine, ';') if trim(c) != ''] ELSE CAST([] AS VARCHAR[]) END,
        -- Raw sport subtags
        CASE WHEN p_sport IS NOT NULL THEN [trim(s) for s in str_split(p_sport, ';') if trim(s) != ''] ELSE CAST([] AS VARCHAR[]) END
      )
    )
  )
  if x IS NOT NULL AND x != '' AND x != p_main_cat
];
