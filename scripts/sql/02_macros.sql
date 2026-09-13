-- 02_macros.sql — Reusable DuckDB Macros for OSM-to-Overture Places Conversion

-- Extract language keys for names: name:<lang>, alt_name, int_name (excluding non-language sub-namespaces & empty strings)
CREATE OR REPLACE MACRO osm_name_keys(props) AS [
    k for k in json_keys(props)
    if (
        (
            k LIKE 'name:%'
            AND k NOT LIKE 'name:%:%'
            AND substring(k, 6) NOT IN ('etymology', 'source', 'botanical', 'prefix', 'genitive', 'left', 'right', 'signed')
        )
        OR k IN ('alt_name', 'int_name')
    )
    AND json_extract_string(props, '$."' || k || '"') != ''
];

-- Extract language keys for brand names (excluding wikidata, wikipedia)
CREATE OR REPLACE MACRO osm_brand_keys(props) AS [
    k for k in json_keys(props)
    if k LIKE 'brand:%'
    AND k NOT LIKE 'brand:%:%'
    AND substring(k, 7) NOT IN ('wikidata', 'wikipedia')
    AND json_extract_string(props, '$."' || k || '"') != ''
];

-- Build MAP(VARCHAR, VARCHAR) of all localized names
CREATE OR REPLACE MACRO osm_names_common(props) AS
CAST(
    map(
        [CASE WHEN k LIKE 'name:%' THEN substring(k, 6) ELSE k END for k in osm_name_keys(props)],
        [json_extract_string(props, '$."' || k || '"') for k in osm_name_keys(props)]
    ) AS MAP(VARCHAR, VARCHAR)
);

-- Build MAP(VARCHAR, VARCHAR) of all localized brand names
CREATE OR REPLACE MACRO osm_brand_common(props) AS
CAST(
    map(
        [substring(k, 7) for k in osm_brand_keys(props)],
        [json_extract_string(props, '$."' || k || '"') for k in osm_brand_keys(props)]
    ) AS MAP(VARCHAR, VARCHAR)
);

-- Identify micro-infrastructure tags (street furniture) that should not be extracted as standalone POIs
CREATE OR REPLACE MACRO is_micro_infrastructure(amenity) AS
amenity IN ('bench', 'waste_basket', 'shelter', 'grit_bin', 'hunting_stand', 'feeding_place', 'waste_disposal', 'ticket_validator');

-- Identify outdoor information micro-infrastructure tags (boards, signposts, maps) that should not be standalone POIs
CREATE OR REPLACE MACRO is_info_micro_infrastructure(tourism, info) AS
tourism = 'information' AND COALESCE(info IN ('board', 'guidepost', 'map', 'terminal', 'audioguide', 'tactile_map', 'tactile_model', 'route_marker', 'signpost'), FALSE);

-- Identify micro-technical man_made tags (cameras, manholes, survey markers, flagpoles, etc.) that should not be standalone POIs
CREATE OR REPLACE MACRO is_micro_man_made(man_made) AS
man_made IN ('surveillance', 'survey_point', 'manhole', 'pipeline', 'pumping_station', 'cutline', 'dyke', 'embankment', 'clearcut', 'flagpole', 'planter', 'street_cabinet', 'water_tap', 'insect_hotel', 'telephone_box');

-- Identify physical & utility infrastructure POIs that qualify even when unnamed/unbranded (geocoder & public service targets)
CREATE OR REPLACE MACRO is_utility_infrastructure(amenity, leisure, emergency) AS
amenity IN ('post_box', 'toilets', 'charging_station', 'parking', 'parking_entrance', 'parcel_locker', 'atm', 'drinking_water', 'recycling', 'taxi')
OR leisure = 'playground'
OR emergency = 'defibrillator';

-- Primary filter: determines whether an OSM feature qualifies as a POI candidate
CREATE OR REPLACE MACRO is_poi_candidate(props) AS
COALESCE(
    (
        json_extract_string(props, '$.name') IS NOT NULL 
        OR json_extract_string(props, '$.brand') IS NOT NULL 
        OR (
            json_extract_string(props, '$.operator') IS NOT NULL 
            AND json_extract_string(props, '$.man_made') IS NULL
        )
        OR is_utility_infrastructure(
            json_extract_string(props, '$.amenity'),
            json_extract_string(props, '$.leisure'),
            json_extract_string(props, '$.emergency')
        )
    )
    AND (
        json_extract_string(props, '$.amenity') IS NOT NULL 
        OR json_extract_string(props, '$.shop') IS NOT NULL 
        OR json_extract_string(props, '$.tourism') IS NOT NULL 
        OR json_extract_string(props, '$.leisure') IS NOT NULL 
        OR json_extract_string(props, '$.office') IS NOT NULL 
        OR json_extract_string(props, '$.craft') IS NOT NULL 
        OR json_extract_string(props, '$.healthcare') IS NOT NULL 
        OR json_extract_string(props, '$.historic') IS NOT NULL 
        OR json_extract_string(props, '$.railway') IS NOT NULL 
        OR json_extract_string(props, '$.aeroway') IS NOT NULL
        OR json_extract_string(props, '$.emergency') = 'defibrillator'
        OR (
            json_extract_string(props, '$.man_made') IS NOT NULL 
            AND NOT is_micro_man_made(json_extract_string(props, '$.man_made'))
            AND (json_extract_string(props, '$.name') IS NOT NULL OR json_extract_string(props, '$.brand') IS NOT NULL)
        )
    )
    AND (
        json_extract_string(props, '$.amenity') IS NULL 
        OR NOT is_micro_infrastructure(json_extract_string(props, '$.amenity'))
        OR json_extract_string(props, '$.shop') IS NOT NULL
        OR (json_extract_string(props, '$.tourism') IS NOT NULL AND json_extract_string(props, '$.tourism') != 'information')
        OR json_extract_string(props, '$.historic') IS NOT NULL
        OR json_extract_string(props, '$.office') IS NOT NULL
        OR json_extract_string(props, '$.craft') IS NOT NULL
        OR json_extract_string(props, '$.healthcare') IS NOT NULL
    )
    AND (
        NOT is_info_micro_infrastructure(json_extract_string(props, '$.tourism'), json_extract_string(props, '$.information'))
        OR json_extract_string(props, '$.shop') IS NOT NULL
        OR json_extract_string(props, '$.historic') IS NOT NULL
        OR json_extract_string(props, '$.office') IS NOT NULL
        OR json_extract_string(props, '$.craft') IS NOT NULL
        OR json_extract_string(props, '$.healthcare') IS NOT NULL
        OR (json_extract_string(props, '$.amenity') IS NOT NULL AND NOT is_micro_infrastructure(json_extract_string(props, '$.amenity')))
        OR json_extract_string(props, '$.leisure') IS NOT NULL
    ),
    FALSE
);

-- Resolve primary name of POI (leaves untagged physical POIs without pseudo-names; decouples operator)
CREATE OR REPLACE MACRO resolve_poi_name(props) AS
COALESCE(
    json_extract_string(props, '$.name'),
    json_extract_string(props, '$.brand')
);

-- Format address array conforming to Overture Places schema
CREATE OR REPLACE MACRO format_address(street, hno, city, postcode, country) AS
CASE 
    WHEN street IS NOT NULL OR postcode IS NOT NULL OR city IS NOT NULL 
    THEN [{
        'freeform': CASE WHEN street IS NOT NULL AND hno IS NOT NULL THEN street || ' ' || hno ELSE street END,
        'locality': city,
        'postcode': postcode,
        'region': NULL,
        'country': country
    }]
    ELSE CAST([] AS struct(freeform varchar, locality varchar, postcode varchar, region varchar, country varchar)[])
END;

-- Overture schema compliant empty rules STRUCT[]
CREATE OR REPLACE MACRO empty_rules() AS
CAST(NULL AS STRUCT(
    variant VARCHAR, 
    "language" VARCHAR, 
    perspectives STRUCT("mode" VARCHAR, countries VARCHAR[]), 
    "value" VARCHAR, 
    "between" DOUBLE[], 
    side VARCHAR
)[]);
