-- 05_relations.sql — Relation & Access Point Membership Resolution
-- Encapsulates macros for resolving parent relations, member roles, and access types.

-- Resolve access type for entrances, gates, and access points
CREATE OR REPLACE MACRO resolve_access_type(amenity, entrance, railway, member_role, parent_feature_kind) AS
CASE 
    WHEN amenity = 'parking_entrance' THEN 'parking'
    WHEN railway = 'subway_entrance' THEN 'transit'
    WHEN entrance IS NOT NULL THEN
        CASE 
            WHEN entrance IN ('service', 'delivery') THEN 'delivery'
            WHEN entrance IN ('emergency', 'exit') THEN 'emergency'
            ELSE 'pedestrian'
        END
    WHEN member_role IN ('entrance', 'exit', 'entry', 'access') AND (parent_feature_kind = 'parking') THEN 'parking'
    WHEN member_role IN ('entrance', 'exit', 'entry', 'access') THEN 'access'
    ELSE NULL
END;
