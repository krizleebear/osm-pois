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

-- Extract all raw OSM tag keys (excluding Osmium internal metadata attributes @type, @id, @version, @timestamp)
CREATE OR REPLACE MACRO osm_raw_keys(props) AS [
    k for k in json_keys(props)
    if not starts_with(k, '@')
];

-- Build MAP(VARCHAR, VARCHAR) of all raw OSM tags (preserves unnormalized keys & values; NULL if feature has no OSM tags)
CREATE OR REPLACE MACRO osm_raw_tags(props) AS
CASE 
    WHEN len(osm_raw_keys(props)) > 0
    THEN CAST(
        map(
            [k for k in osm_raw_keys(props)],
        [json_extract_string(props, '$."' || replace(replace(k, '\', '\\'), '"', '\"') || '"') for k in osm_raw_keys(props)]
    ) AS MAP(VARCHAR, VARCHAR)
    )
    ELSE NULL
END;

-- Compute the metric footprint area (square meters, integer) of polygon/multipolygon POI geometries.
-- WGS84 lon/lat GeoJSON geometries (standard [x,y]=[lon,lat] axis order used throughout this
-- pipeline) are transformed to the global equal-area EASE-Grid 2.0 / WGS84 projection
-- (EPSG:6933) and the planar ST_Area yields the footprint in square meters. EPSG:6933 is
-- the single cylindrical equal-area projection bundled in the DuckDB PROJ database that is
-- valid worldwide (including high latitudes, e.g. Nordic and Canadian extracts).
-- Returns an INTEGER count of square meters (rounded); NULL for point / non-area geometries.
CREATE OR REPLACE MACRO osm_area_sqm(geom) AS
CASE 
    WHEN geom IS NOT NULL AND ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON')
    THEN ROUND(ST_Area(ST_Transform(geom, 'EPSG:4326', 'EPSG:6933', always_xy := true)))::BIGINT
    ELSE NULL
END;

-- Identify micro-infrastructure tags (street furniture) that should not be extracted as standalone POIs
CREATE OR REPLACE MACRO is_micro_infrastructure(amenity) AS
list_contains(['bench', 'waste_basket', 'shelter', 'grit_bin', 'hunting_stand', 'feeding_place', 'waste_disposal', 'ticket_validator'], amenity);

-- Identify outdoor information micro-infrastructure tags (boards, signposts, maps) that should not be standalone POIs
CREATE OR REPLACE MACRO is_info_micro_infrastructure(tourism, info) AS
tourism = 'information' AND COALESCE(list_contains(['board', 'guidepost', 'map', 'terminal', 'audioguide', 'tactile_map', 'tactile_model', 'route_marker', 'signpost'], info), FALSE);

-- Identify micro-technical man_made tags (cameras, manholes, survey markers, flagpoles, etc.) that should not be standalone POIs
CREATE OR REPLACE MACRO is_micro_man_made(man_made) AS
list_contains(['surveillance', 'survey_point', 'manhole', 'pipeline', 'pumping_station', 'cutline', 'dyke', 'embankment', 'clearcut', 'flagpole', 'planter', 'street_cabinet', 'water_tap', 'insect_hotel', 'telephone_box'], man_made);

-- Identify physical & utility infrastructure POIs that qualify even when unnamed/unbranded (geocoder & public service targets)
CREATE OR REPLACE MACRO is_utility_infrastructure(amenity, leisure, emergency, highway := NULL) AS
list_contains(['post_box', 'toilets', 'charging_station', 'parking', 'parking_entrance', 'parcel_locker', 'atm', 'drinking_water', 'recycling', 'taxi'], amenity)
OR leisure = 'playground'
OR emergency = 'defibrillator'
OR list_contains(['rest_area', 'services'], highway);

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
            json_extract_string(props, '$.emergency'),
            json_extract_string(props, '$.highway')
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
        OR json_extract_string(props, '$.highway') IN ('rest_area', 'services')
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

-- Helper macros for names.rules extraction
CREATE OR REPLACE MACRO rule_variant(k) AS
  CASE 
    WHEN k LIKE 'alt_name%' THEN 'alternate'
    WHEN k LIKE 'nickname%' THEN 'alternate'
    WHEN k LIKE 'official_name%' THEN 'official'
    WHEN k LIKE 'short_name%' THEN 'short'
    WHEN k LIKE 'loc_name%' THEN 'local'
    WHEN k LIKE 'reg_name%' THEN 'regional'
    WHEN k LIKE 'int_name%' THEN 'international'
    ELSE 'alternate'
  END;

CREATE OR REPLACE MACRO rule_lang(k) AS
  CASE WHEN k LIKE '%:%' THEN split_part(k, ':', 2) ELSE NULL END;

CREATE OR REPLACE MACRO osm_name_rule_keys(props) AS [
  k for k in json_keys(props)
  if (
    k IN ('alt_name', 'official_name', 'short_name', 'loc_name', 'reg_name', 'int_name', 'nickname')
    OR (k LIKE 'alt_name:%' AND k NOT LIKE 'alt_name:%:%')
    OR (k LIKE 'official_name:%' AND k NOT LIKE 'official_name:%:%')
    OR (k LIKE 'short_name:%' AND k NOT LIKE 'short_name:%:%')
    OR (k LIKE 'loc_name:%' AND k NOT LIKE 'loc_name:%:%')
    OR (k LIKE 'reg_name:%' AND k NOT LIKE 'reg_name:%:%')
    OR (k LIKE 'nickname:%' AND k NOT LIKE 'nickname:%:%')
  )
  AND json_extract_string(props, '$."' || k || '"') != ''
];

-- Build Overture-conforming STRUCT[] for names.rules
CREATE OR REPLACE MACRO osm_names_rules(props) AS
  CASE 
    WHEN len(osm_name_rule_keys(props)) = 0 
    THEN empty_rules()
    ELSE [
      {
        'variant': rule_variant(k),
        'language': rule_lang(k),
        'perspectives': CAST(NULL AS STRUCT("mode" VARCHAR, countries VARCHAR[])),
        'value': json_extract_string(props, '$."' || k || '"'),
        'between': CAST(NULL AS DOUBLE[]),
        'side': CAST(NULL AS VARCHAR)
      }
      for k in osm_name_rule_keys(props)
    ]
  END;

-- Helper macro to format social media URLs from handles or raw URLs
CREATE OR REPLACE MACRO format_social_url(platform_url, raw_val) AS
CASE 
    WHEN raw_val IS NULL OR trim(raw_val) = '' THEN NULL
    WHEN lower(trim(raw_val)) LIKE 'http://%' OR lower(trim(raw_val)) LIKE 'https://%' THEN trim(raw_val)
    WHEN lower(trim(raw_val)) LIKE 'www.%' THEN 'https://' || trim(raw_val)
    WHEN lower(trim(raw_val)) LIKE '%facebook.com/%' OR lower(trim(raw_val)) LIKE '%instagram.com/%' OR lower(trim(raw_val)) LIKE '%twitter.com/%' OR lower(trim(raw_val)) LIKE '%x.com/%' OR lower(trim(raw_val)) LIKE '%linkedin.com/%' OR lower(trim(raw_val)) LIKE '%youtube.com/%' OR lower(trim(raw_val)) LIKE '%tiktok.com/%' THEN 'https://' || regexp_replace(trim(raw_val), '^https?://', '')
    WHEN platform_url LIKE '%linkedin.com%' AND (lower(trim(raw_val)) LIKE 'in/%' OR lower(trim(raw_val)) LIKE 'company/%') THEN 'https://www.linkedin.com/' || trim(raw_val)
    ELSE platform_url || regexp_replace(regexp_replace(trim(raw_val), '^@', ''), '^/+', '')
END;

-- Extract socials array conforming to Overture schema (VARCHAR[])
CREATE OR REPLACE MACRO extract_socials(props) AS
[
  s for s in list_distinct([
    format_social_url(
      'https://www.facebook.com/', 
      COALESCE(json_extract_string(props, '$.contact:facebook'), json_extract_string(props, '$.facebook'))
    ),
    format_social_url(
      'https://www.instagram.com/', 
      COALESCE(json_extract_string(props, '$.contact:instagram'), json_extract_string(props, '$.instagram'))
    ),
    format_social_url(
      'https://x.com/', 
      COALESCE(json_extract_string(props, '$.contact:twitter'), json_extract_string(props, '$.contact:x'), json_extract_string(props, '$.twitter'))
    ),
    format_social_url(
      'https://www.linkedin.com/company/', 
      COALESCE(json_extract_string(props, '$.contact:linkedin'), json_extract_string(props, '$.linkedin'))
    ),
    format_social_url(
      'https://www.youtube.com/', 
      COALESCE(json_extract_string(props, '$.contact:youtube'), json_extract_string(props, '$.youtube'))
    ),
    format_social_url(
      'https://www.tiktok.com/@', 
      COALESCE(json_extract_string(props, '$.contact:tiktok'), json_extract_string(props, '$.tiktok'))
    )
  ])
  if s IS NOT NULL AND s != ''
];
