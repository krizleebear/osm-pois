# Specification: Upstream POI Confidence & Quality Scoring from OSM PBF

**Version:** 1.1  
**Target Repository:** `osm-pois` (Upstream Extractor) & `osm-geocoder`  
**Author:** Antigravity / osm-geocoder Team  
**Date:** 2026-09-13  
**Status:** Approved / Production Architecture  

---

## 1. Executive Summary & Objective

In the Overture Maps schema, each place/POI record carries a `confidence` field (`DOUBLE`, range `0.00` to `1.00`). In earlier upstream OSM extractions, this value was uniformly static (`0.80` across all records).

The downstream geocoding engine (`osm-geocoder`) relies heavily on `confidence` for:
1. **Disambiguation & Deduplication:** When multiple places share similar names or coordinates, confidence breaks ties deterministically.
2. **POI Importance & Ranking:** The `PoiScorer` combines priority tiers with confidence to produce search rank scores.
3. **Spam & Stale Data Filtering:** Filtering or demoting places that have likely closed, lack verification, or were mapped haphazardly.

While downstream systems only see the flattened Parquet schema (`names`, `categories`, `addresses`, `brand`, `phones`, `websites`), **upstream has exclusive access to the full OSM PBF stream**. Upstream can leverage raw tags, object metadata, and spatial topology that are dropped during extraction.

This specification defines a deterministic, lightweight, rule-based scoring engine for upstream PBF extraction, accompanied by an approved non-breaking Superset extension of operational attributes.

---

## 2. PBF Input Signals

The following signals are evaluated by upstream during entity extraction from the OSM PBF stream:

### 2.1 Explicit Ground Verification Tags
OSM mappers explicitly document ground surveys using verification tags:
* `check_date=*` (ISO 8601 date, e.g. `2025-04-12`, `2024-11`, `2023`)
* `survey:date=*`
* `lastcheck=*`

### 2.2 Domain Tag Richness (Operational Depth)
Detailed functional attributes are only entered when a business or facility actively exists. These tags are typically omitted in bulk/draft imports:
* `opening_hours=*` (e.g. `Mo-Fr 08:00-18:00`)
* `wheelchair=*` (`yes`, `limited`, `no`, `designated`)
* `payment:*=*` (e.g. `payment:credit_cards=yes`, `payment:cash=yes`, `payment:contactless=yes`)
* `cuisine=*` (for restaurants/cafes)
* `takeaway=*`, `delivery=*`
* `operator=*`
* `contact:email=*`, `contact:website=*`, `contact:phone=*` (when not already extracted to top-level)

### 2.3 Individual Entity Identity
* `wikidata=*` on the POI itself (distinct from `brand:wikidata`). Indicates an independently notable institution, historic site, hospital, university, or landmark.
* `wikipedia=*` on the POI itself.
* Official identifiers: `ref:vatin=*`, `de:amtlicher_gemeindeschluessel=*`.

### 2.4 Structural & Spatial Anchoring (Topology: Self-Anchoring)
* **POI Polygon / Way Geometry:** POI is mapped as a closed way or multipolygon relation (`ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON')` or OSM ID starts with `osm:way/` or `osm:relation/`).
* **Building Tag:** POI explicitly carries a `building=*` or `building:part=*` tag.
* **Architectural Note on Spatial Containment:** Point-in-polygon spatial joining of standalone node POIs against external, non-POI building polygons is **deliberately omitted**. In our zero-disk 1-pass streaming pipeline (`osmium tags-filter` $\to$ FIFO $\to$ DuckDB), non-POI residential and commercial buildings are filtered out to keep resource usage minimal. Self-anchoring (POI geometry is polygon or carries a building tag) provides a robust, zero-cost proxy for verified structural anchoring without memory explosion.

### 2.5 Negative Quality & Lifecycle Indicators
* **Lifecycle Prefixes & Keys:**
  * `disused=*`, `abandoned=*` (e.g. `disused=yes`, `abandoned=yes`)
  * Keys using lifecycle prefixes: `disused:*=*`, `abandoned:*=*`, `was:*=*`, `demolished:*=*`
  * `end_date=*`
* **Uncertainty & FIXME notes:**
  * `fixme=*` / `FIXME=*`
  * `note=*` with closure or doubt keywords: `"closed"`, `"geschlossen"`, `"prüfen"`, `"existiert nicht mehr"`, `"demolished"`, `"abgerissen"`, `"weg"`, `"dauerhaft geschlossen"`, `"permanently closed"`.
* **Retention Policy:** POIs carrying an active primary category (e.g. `amenity=restaurant`) but flagged with closure or disused indicators are **retained** in Parquet, but penalized with a heavy confidence deduction (resulting in scores between `0.10` and `0.25`). This allows downstream search engines to either filter them out or use them for historical/stale search queries.

### 2.6 PBF Object Metadata (Recency & Activity)
* `timestamp`: UTC timestamp of the last edit (`@timestamp` from Osmium).
* `version`: Revision number of the OSM entity (`@version` from Osmium).

---

## 3. Scoring Model & Formula

The scoring algorithm calculates `confidence` through a base score modified by additive bonuses and subtractive penalties:

$$\text{confidence} = \text{round}\left(\text{clamp}\left(0.10,\, 0.99,\, \text{Base} + \min(0.39,\, \sum \text{Bonus}) - \sum \text{Penalty}\right),\, 2\right)$$

### 3.1 Base Score
* Default base score for any extracted POI passing category and name validity:  
  $$\text{Base} = 0.60$$

### 3.2 Additive Bonuses ($+\text{Bonus}$)

| Criterion | Condition | Bonus | Rationale |
| :--- | :--- | :--- | :--- |
| **Recent Survey** | `check_date`, `survey:date`, or `lastcheck` $\ge \text{Year} - 2$ | **+0.15** | Highest proof of physical on-site existence. |
| **Older Survey** | Survey date between $\text{Year} - 5$ and $\text{Year} - 3$ | **+0.08** | Confirmed within typical small-business lifecycle. |
| **Opening Hours** | `opening_hours` tag present and non-empty | **+0.10** | Strongest indicator of active commercial operation. |
| **Contact Channels** | Valid `website` OR `phone` present | **+0.08** | Business maintains public contact information. |
| **Entity Wikidata** | Direct `wikidata` or `wikipedia` on the POI | **+0.06** | Notable institution or recognized landmark. |
| **Tag Richness** | $\ge 2$ operational tags (`wheelchair`, `payment:*`, `cuisine`, `delivery`, `takeaway`) | **+0.05** | Deep, conscientious mapping quality. |
| **Building Anchor** | POI is polygon/way OR carries `building=*` / `building:part=*` | **+0.05** | Physical structural anchoring verified. |
| **Mature Revision** | OSM entity `version` $\ge 3$ | **+0.03** | Multiple community reviews/edits over time. |

*Note: The cumulative bonus is capped at $+0.39$ to ensure $\text{Base} + \text{Bonus} \le 0.99$.*

---

### 3.3 Subtractive Penalties ($-\text{Penalty}$)

| Criterion | Condition | Penalty | Rationale |
| :--- | :--- | :--- | :--- |
| **Closure / Doubt Note** | `fixme` or `note` matches closure pattern | **-0.35** | Explicit mapper doubt or pending deletion. |
| **Lifecycle / Disused** | `disused=yes`, `abandoned=yes`, `end_date=*`, or disused prefix | **-0.40** | Out of operation or decommissioned. |
| **Stale Record** | `timestamp` older than 8 years AND no contact data | **-0.15** | Unconfirmed in high-turnover sectors. |
| **Minimal / Sparse Node** | Only `name` + `category`, no contact/address/attributes, `version=1` | **-0.08** | Quick draft mapping without verification. |

---

## 4. Reference Calibration & Target Distribution

After applying the formula, the confidence distribution across a nationwide dataset (e.g. Germany) conforms to the following target distribution:

```
┌────────────────────────────────────────────────────────┐
│  Confidence Score Distribution                         │
├─────────────────┬─────────────┬────────────────────────┤
│ Range           │ Share (%)   │ Typical Profile        │
├─────────────────┼─────────────┼────────────────────────┤
│ 0.90 – 0.99     │  15 – 25%   │ Freshly surveyed, full │
│                 │             │ contact & hours, wiki  │
│ 0.80 – 0.89     │  35 – 45%   │ Standard well-mapped   │
│                 │             │ venue with contacts    │
│ 0.60 – 0.79     │  25 – 35%   │ Basic POI without hours│
│                 │             │ or direct verification │
│ 0.10 – 0.59     │   5 – 10%   │ Stale, sparse, or with │
│                 │             │ fixme/doubt/disused    │
└─────────────────┴─────────────┴────────────────────────┘
```

---

## 5. Technical Implementation Details for DuckDB Pipeline

1. **Modular SQL Component:**
   * Logic is encapsulated in `scripts/sql/04_confidence.sql` as a pure DuckDB SQL macro:
     `calculate_poi_confidence(props, geom, osm_version, osm_timestamp, has_contact, ref_year := year(current_date))`
   * Passing `ref_year` parameter defaults dynamically to `year(current_date)` in production, but allows deterministic, fixed-year evaluation (e.g. `ref_year := 2026`) in unit tests.
2. **Date Parsing:**
   * Extracts year via `TRY_CAST(regexp_extract(val, '^[0-9]{4}') AS INTEGER)`.
3. **Closure Regex Pattern:**
   ```regex
   (?i)\b(geschlossen|closed|demolished|abgerissen|weg|nicht mehr|does not exist|dauerhaft geschlossen|permanently closed)\b
   ```
4. **Dynamic Payment Methods Extraction:**
   * Evaluated dynamically from `json_keys(properties)`:
     ```sql
     list_sort([substring(k, 9) for k in json_keys(props) if k LIKE 'payment:%' AND json_extract_string(props, '$."' || k || '"') IN ('yes', 'only')])
     ```
5. **Performance Invariant:**
   * All tag extractions execute vectorized in DuckDB memory without subqueries, external network lookups, or intermediate disk writes.

---

## 6. Extended POI Attributes (Parquet Superset Extension)

> **Overture Schema Alignment:** The official Overture Maps `place` schema (as of 2026) omits operational fields such as opening hours, cuisine, payment methods, and wheelchair accessibility.  
> `osm-pois` emits these columns as an **official, non-breaking Superset Extension** directly into `places.parquet`. Standard Parquet engines ignore these unrequested columns via projection pushdown, while downstream geocoders (`osm-geocoder`) and rich map viewers consume them directly.

The following 8 extended attributes are added to the Parquet output schema:

| Parquet Column | Parquet Type | OSM Source Tags | Example Value | Description |
| :--- | :--- | :--- | :--- | :--- |
| `opening_hours` | `VARCHAR` | `opening_hours` | `Mo-Fr 08:00-18:00; Sa 09:00-13:00` | Human-readable & machine-parseable operating times. |
| `cuisine` | `VARCHAR` | `cuisine` | `italian;pizza`, `regional`, `vietnamese` | Gastronomy culinary style or food specialty. |
| `wheelchair` | `VARCHAR` | `wheelchair` | `yes`, `limited`, `no`, `designated` | Physical accessibility status for mobility-impaired users. |
| `payment_methods` | `VARCHAR[]` | `payment:*=yes/only` | `["cash", "credit_cards", "contactless"]` | Normalized, sorted list of accepted payment types. |
| `level` | `VARCHAR` | `level`, `layer` | `0`, `1`, `-1` | Floor or vertical level within building/complex. |
| `operator` | `VARCHAR` | `operator` | `Deutsche Post AG`, `Stadtwerke München` | Operating entity (distinct from brand and POI name). |
| `delivery` | `VARCHAR` | `delivery` | `yes`, `no` | Delivery service availability. |
| `takeaway` | `VARCHAR` | `takeaway` | `yes`, `no`, `only` | Takeaway / pickup availability. |
