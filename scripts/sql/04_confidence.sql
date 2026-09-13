-- 04_confidence.sql — Upstream POI Confidence Scoring & Operational Tag Extractions
-- Strictly implements docs/SPEC_OSM_POI_CONFIDENCE.md (v1.1)

-- Extract and sort accepted payment methods from payment:*=yes/only tags
CREATE OR REPLACE MACRO extract_payment_methods(props) AS
list_sort([
    substring(k, 9) for k in json_keys(props)
    if k LIKE 'payment:%'
    AND k NOT LIKE 'payment:%:%'
    AND json_extract_string(props, '$."' || k || '"') IN ('yes', 'only')
]);

-- Extract level / layer vertical elevation
CREATE OR REPLACE MACRO extract_poi_level(props) AS
COALESCE(
    json_extract_string(props, '$.level'),
    json_extract_string(props, '$.layer')
);

-- Calculate deterministic POI confidence score based on PBF signals
CREATE OR REPLACE MACRO calculate_poi_confidence(
    props,
    is_polygon,
    osm_version,
    osm_timestamp,
    has_website,
    has_phone,
    ref_year := year(current_date)
) AS (
    WITH raw_signals AS (
        SELECT
            TRY_CAST(regexp_extract(
                COALESCE(
                    json_extract_string(props, '$.check_date'),
                    json_extract_string(props, '$."survey:date"'),
                    json_extract_string(props, '$.lastcheck')
                ),
                '^[0-9]{4}'
            ) AS INTEGER) AS survey_year,

            json_extract_string(props, '$.opening_hours') AS raw_opening_hours,

            json_extract_string(props, '$.wikidata') AS raw_wikidata,
            json_extract_string(props, '$.wikipedia') AS raw_wikipedia,

            (
                (CASE WHEN json_extract_string(props, '$.wheelchair') IS NOT NULL THEN 1 ELSE 0 END) +
                (CASE WHEN json_extract_string(props, '$.cuisine') IS NOT NULL THEN 1 ELSE 0 END) +
                (CASE WHEN json_extract_string(props, '$.delivery') IS NOT NULL THEN 1 ELSE 0 END) +
                (CASE WHEN json_extract_string(props, '$.takeaway') IS NOT NULL THEN 1 ELSE 0 END) +
                (CASE WHEN len([k for k in json_keys(props) if k LIKE 'payment:%' AND json_extract_string(props, '$."' || k || '"') IN ('yes', 'only')]) > 0 THEN 1 ELSE 0 END)
            ) AS operational_count,

            COALESCE(json_extract_string(props, '$.note'), '') || ' ' ||
            COALESCE(json_extract_string(props, '$.fixme'), '') || ' ' ||
            COALESCE(json_extract_string(props, '$.FIXME'), '') AS note_text,

            (
                COALESCE(json_extract_string(props, '$.disused'), '') NOT IN ('', 'no')
                OR COALESCE(json_extract_string(props, '$.abandoned'), '') NOT IN ('', 'no')
                OR json_extract_string(props, '$.end_date') IS NOT NULL
                OR len([k for k in json_keys(props) if k LIKE 'disused:%' OR k LIKE 'abandoned:%' OR k LIKE 'was:%' OR k LIKE 'demolished:%']) > 0
            ) AS is_lifecycle_disused,

            TRY_CAST(substring(osm_timestamp, 1, 4) AS INTEGER) AS osm_year
    ),
    evaluated_signals AS (
        SELECT
            -- 1. Survey recency
            CASE 
                WHEN survey_year IS NOT NULL AND survey_year >= ref_year - 2 THEN 0.15
                WHEN survey_year IS NOT NULL AND survey_year BETWEEN ref_year - 5 AND ref_year - 3 THEN 0.08
                ELSE 0.0
            END AS bonus_survey,

            -- 2. Opening hours
            CASE 
                WHEN raw_opening_hours IS NOT NULL AND trim(raw_opening_hours) != '' 
                THEN 0.10 
                ELSE 0.0 
            END AS bonus_hours,

            -- 3. Contact channels
            CASE 
                WHEN has_website OR has_phone 
                THEN 0.08 
                ELSE 0.0 
            END AS bonus_contact,

            -- 4. Entity Wikidata / Wikipedia
            CASE 
                WHEN raw_wikidata IS NOT NULL OR raw_wikipedia IS NOT NULL 
                THEN 0.06 
                ELSE 0.0 
            END AS bonus_wiki,

            -- 5. Operational tag richness
            CASE 
                WHEN operational_count >= 2 
                THEN 0.05 
                ELSE 0.0 
            END AS bonus_richness,

            -- 6. Building Anchor (Self-anchoring)
            CASE 
                WHEN is_polygon 
                  OR json_extract_string(props, '$.building') IS NOT NULL 
                  OR json_extract_string(props, '$."building:part"') IS NOT NULL 
                THEN 0.05 
                ELSE 0.0 
            END AS bonus_building,

            -- 7. Mature revision (version >= 3)
            CASE 
                WHEN osm_version IS NOT NULL AND osm_version >= 3 
                THEN 0.03 
                ELSE 0.0 
            END AS bonus_version,

            -- Negative 1: Closure / Doubt notes
            CASE 
                WHEN regexp_matches(note_text, '(?i)\b(geschlossen|closed|demolished|abgerissen|weg|nicht mehr|does not exist|dauerhaft geschlossen|permanently closed)\b') 
                THEN 0.35 
                ELSE 0.0 
            END AS penalty_note,

            -- Negative 2: Lifecycle / Disused
            CASE 
                WHEN is_lifecycle_disused 
                THEN 0.40 
                ELSE 0.0 
            END AS penalty_lifecycle,

            -- Negative 3: Stale record (> 8 years without contacts)
            CASE 
                WHEN osm_year IS NOT NULL 
                 AND osm_year <= ref_year - 8 
                 AND NOT (has_website OR has_phone) 
                THEN 0.15 
                ELSE 0.0 
            END AS penalty_stale,

            -- Negative 4: Minimal / Sparse node
            CASE 
                WHEN (osm_version IS NULL OR osm_version = 1)
                 AND NOT is_polygon
                 AND json_extract_string(props, '$.building') IS NULL
                 AND NOT (has_website OR has_phone)
                 AND (raw_opening_hours IS NULL OR trim(raw_opening_hours) = '')
                 AND json_extract_string(props, '$.addr:street') IS NULL
                 AND json_extract_string(props, '$.addr:postcode') IS NULL
                 AND operational_count = 0
                THEN 0.08 
                ELSE 0.0 
            END AS penalty_minimal
        FROM raw_signals
    )
    SELECT
        round(
            greatest(
                0.10,
                least(
                    0.99,
                    0.60 
                    + least(0.39, bonus_survey + bonus_hours + bonus_contact + bonus_wiki + bonus_richness + bonus_building + bonus_version)
                    - (penalty_note + penalty_lifecycle + penalty_stale + penalty_minimal)
                )
            ),
            2
        )::DOUBLE
    FROM evaluated_signals
);
