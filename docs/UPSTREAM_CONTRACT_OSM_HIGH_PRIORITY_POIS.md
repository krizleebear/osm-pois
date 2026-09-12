# 🏛️ Upstream Data Contract: OSM High-Priority POIs

**Dataset Target:** `osm-pois-{CC}.parquet` (z. B. `osm-pois-DE.parquet`, `osm-pois-FR.parquet`)  
**Upstream Pipeline / Repository:** `osm-polygons` / `osm-tools` / OSM Extractor  
**Format:** Apache Parquet / GeoParquet (WGS84 / EPSG:4326 / OGC:CRS84)  
**Bezugsspezifikation (Downstream):** [`SPEC_OSM_HIGH_PRIORITY_POIS.md`](SPEC_OSM_HIGH_PRIORITY_POIS.md)

---

## 1. Übersicht & Zielsetzung

Dieser Data Contract definiert die Anforderungen an den Upstream-Datensatz `osm-pois-{CC}.parquet`. Der Datensatz dient als autoritative, verlässliche Primärquelle für **Priority Tier 1 (P1)** und **Priority Tier 2 (P2)** Points of Interest (POIs) im Geocoder-System.

### Problemstellung im Downstream-System
Bestehende POI-Quellen (wie Overture Maps Places) weisen bei prominenten Landmarken und Hauptanlagen erhebliche Qualitätsmängel auf:
- Untereinheiten innerhalb von Flughäfen (z. B. Cafés, Bars, Lounges, Parkhäuser, Training Centers) werden fälschlich als eigenständige `category = airport` klassifiziert und drängen als falsche P1-Objekte in die Ausgabe.
- Bahn-Plattformen, Haltepunkte oder U-Bahn-Eingänge werden als überregionale Fernbahnhöfe ausgegeben.
- Krankenhäuser und Universitäten werden in Dutzende Einzelgebäude oder Institute zersplittert, statt die Gesamteinrichtung als Primärrepräsentant auszuweisen.

### Aufgabe des Upstream-Artefakts
Der Upstream-Prozess extrahiert aus den aktuellen OpenStreetMap-Rohdaten (PBF) pro ISO-3166-1-Land einen dedizierten, stark qualitätsgefilterten POI-Datensatz. Das Upstream-Artefakt liefert:
1. Saubere Repräsentationspunkte auf der Objektfläche (**Interior Point**, niemals Centroid).
2. Original-Footprints für Flächen- und Relations-Objekte (`Polygon` / `MultiPolygon`).
3. Vorab gefilterte, verlässliche Hauptanlagen unter striktem Ausschluss von Untereinheiten, Ruinen und inaktiven Objekten.
4. Bereinigte Tag-Projektionen im JSON-Format für Fusion und Evaluierung.

---

## 2. Parquet Tabellenschema

Jede Datei `osm-pois-{CC}.parquet` muss exakt folgendem Schema entsprechen:

| Spalte | Parquet / DuckDB Typ | Nullable | Beschreibung & Format |
| :--- | :--- | :---: | :--- |
| `continent` | `VARCHAR` | Nein | Kontinent-Kürzel in Kleinbuchstaben (z. B. `'europe'`). |
| `country_code` | `VARCHAR` | Nein | ISO 3166-1 Alpha-2 Ländercode (z. B. `'DE'`, `'FR'`, `'MC'`). |
| `osm_id` | `BIGINT` | Nein | Eindeutige, positive OpenStreetMap-Element-ID. |
| `osm_type` | `VARCHAR` | Nein | OSM-Objekttyp: `'N'` (Node), `'W'` (Way), `'R'` (Relation). |
| `feature_class` | `VARCHAR` | Nein | Kanonischer Extraktionsschlüssel (siehe Abschnitt 5). |
| `geom` | `GEOMETRY` | Nein | Repräsentationspunkt als WGS84 Point (`EPSG:4326`). |
| `footprint` | `GEOMETRY` | Ja | Originale Flächengeometrie (`Polygon` / `MultiPolygon`), `NULL` für reine Nodes. |
| `tags` | `VARCHAR` (JSON) | Nein | Selektierte Roh-Tags als valides JSON-Objekt (siehe Abschnitt 6). |

### Metadaten & GeoParquet-Standard
- Die Parquet-Datei muss gültige **GeoParquet-Metadaten** (Version 1.0 oder 1.1) im File-Footer besitzen.
- Die primäre Geometriespalte ist `geom` (CRS: `OGC:CRS84` bzw. `EPSG:4326`).
- Die optionale Flächenspalte `footprint` muss als sekundäre Geometriespalte in den Metadaten deklariert sein.

---

## 3. Geometrie- & Topologieanforderungen

### 3.1 Point-on-Surface Invariante (Kein Centroid!)
- Für linien- oder flächenhafte Objekte (Ways und Relationen) **DARF NIEMALS der geometrische Schwerpunkt (`ST_Centroid`)** als `geom` verwendet werden.
- **Vorgeschriebene Berechnung:** `geom = ST_PointOnSurface(footprint)`.
- **Begründung:** Bei U-förmigen Gebäuden, gebogenen Flughafenterminals, kreisrunden Stadien oder Arealen mit Innenhöfen liegt der Centroid regelmäßig außerhalb des Gebäudes, in Gewässern oder auf benachbarten Grundstücken.
- **Invariante:** Wenn `footprint IS NOT NULL`, MUSS zwingend gelten:
  ```sql
  ST_Intersects(footprint, geom) = TRUE
  ```

### 3.2 Footprint-Qualität & Validität
- Polygone und Multipolygone müssen topologisch valide sein: `ST_IsValid(footprint) = TRUE`.
- Selbstdurchdringungen und ungültige Ringfolgen müssen vor der Extraktion repariert werden (z. B. `ST_MakeValid`).
- Relations-Multipolygone müssen vollständige `outer`- und `inner`-Ringe abbilden.

### 3.3 Koordinaten-Validierung
- Gültigkeitsbereich: $-180.0 \le \text{lon} \le 180.0$ und $-90.0 \le \text{lat} \le 90.0$.
- `geom` darf weder `NULL`, `EMPTY` noch `NaN`/`Infinity`-Koordinaten enthalten.

---

## 4. OSM-interne Deduplizierung & Repräsentantenauswahl

In OpenStreetMap wird ein reales Objekt häufig mehrfach erfasst (z. B. ein Punkt für den Haupteingang oder die Adresse und eine Fläche/Relation für das Areal oder Gebäude).

### 4.1 Verschmelzungsregel (Node + Area Consolidation)
Falls im selben PBF-Extrakt für dasselbe Objekt sowohl ein Punkt (`osm_type = 'N'`) als auch eine Fläche (`osm_type IN ('W', 'R')`) vorliegen:
1. **Bedingung für Übereinstimmung:**
   - Identische `wikidata`-ID **ODER**
   - Identischer normalisierter `name` bei identischer `feature_class` **UND** der Node liegt geometrisch innerhalb der Fläche (`ST_Contains(area.footprint, node.geom)`).
2. **Konsolidierung:**
   - Es wird **genau ein Datensatz** in die Parquet-Datei geschrieben.
   - Der Flächen-Datensatz (`W` oder `R`) hat Vorrang für `footprint`.
   - Als `geom` wird bevorzugt der Node-Punkt verwendet (sofern er innerhalb des Footprints liegt), da er oft den konkreten Besuchereingang markiert; andernfalls `ST_PointOnSurface(footprint)`.
   - Die `tags` beider Objekte werden zusammengeführt (Flächen-Attribute überschreiben / ergänzen Node-Attribute).
   - Der isolierte Node wird verworfen, um Duplikate im Geocoder zu verhindern.

---

## 5. Feature Classes & OSM-Extraktionsregeln

Die erste Ausbaustufe beschränkt sich auf eine konservative Whitelist prominenter POI-Klassen. Nicht aufgeführte Features werden upstream verworfen.

### 5.1 Übersicht der Feature Classes

| `feature_class` | Ziel-Kategorie | Primärer OSM-Tag | Erforderliche Evidenz & Filter |
| :--- | :--- | :--- | :--- |
| `airport` | Internationaler / Regionalflughafen | `aeroway = aerodrome` | `iata IS NOT NULL OR icao IS NOT NULL`; Ausschluss privater/militärischer Kleinflugfelder (siehe 5.2). |
| `station` | Fern- & Regionalbahnhof | `railway = station` | Kein `station = subway`; kein Güter-/Rangierbahnhof. |
| `hospital` | Krankenhaus / Klinikum | `amenity = hospital` | Gesamtanlage/Klinikum; keine Einzelpraxen oder reine Fachambulanzen. |
| `university` | Universität / Hochschule | `amenity = university` | Hauptcampus / Gesamtareal; keine Studentenwohnheime oder Schulen. |
| `museum` | Museum | `tourism = museum` | Öffentlich zugängliches Museum; keine temporären Ausstellungen. |
| `zoo` | Zoo / Tierpark | `tourism = zoo` | Hauptanlage; keine einzelnen Gehege. |
| `aquarium` | Aquarium / Großaquarium | `tourism = aquarium` | Hauptanlage. |
| `theme_park` | Freizeitpark | `tourism = theme_park` | Hauptanlage; keine Einzelattraktionen. |
| `stadium` | Stadion / Großarena | `leisure = stadium` | Hauptstadion; keine einfachen Bolzplätze oder Turnhallen. |
| `castle` | Schloss / Burg | `historic = castle` | Hauptanlage; keine Ruinenreste ohne Substanz. |
| `monument` | Bedeutendes Denkmal | `historic = monument` | Freistehendes, herausragendes Monument mit Eigennamen. |
| `mall` | Einkaufszentrum | `shop = mall` | Gesamtes Center; keine einzelnen Ladengeschäfte. |
| `theatre` | Theater / Oper | `amenity = theatre` | Hauptspielstätte / Opernhaus; keine Kinos oder Ticketkioske. |

---

### 5.2 Detaillierte Filter- & Ausschlusskriterien pro Klasse

#### A. `airport`
* **Einschluss:**
  ```sql
  WHERE tags->>'aeroway' = 'aerodrome'
    AND (tags->>'iata' IS NOT NULL OR tags->>'icao' IS NOT NULL)
  ```
* **Ausschlüsse:**
  - `aerodrome:type IN ('glider', 'ultralight')`
  - `aeroway IN ('helipad', 'runway', 'taxiway', 'apron', 'hangar', 'terminal', 'gate')`
  - Militär-Only Flugplätze ohne zivile Nutzung (`military = airfield` ohne IATA/ICAO).

#### B. `station`
* **Einschluss:**
  ```sql
  WHERE tags->>'railway' = 'station'
  ```
* **Ausschlüsse:**
  - `tags->>'station' IN ('subway', 'light_rail')`
  - `tags->>'railway' IN ('halt', 'tram_stop', 'platform', 'stop_position')`
  - `tags->>'service' IN ('yard', 'siding', 'spur', 'crossover')`
  - `tags->>'usage' = 'freight'` (sofern keine Personenbeförderung stattfindet).

#### C. `hospital`
* **Einschluss:**
  ```sql
  WHERE tags->>'amenity' = 'hospital'
  ```
* **Ausschlüsse:**
  - `tags->>'amenity' IN ('doctors', 'clinic', 'pharmacy', 'dentist')`
  - Einzelne Pavillons oder Abteilungen: `tags->>'hospital:unit' IS NOT NULL` oder `tags->>'building' IN ('chapel', 'garage', 'parking')`.

#### D. `university`
* **Einschluss:**
  ```sql
  WHERE tags->>'amenity' = 'university'
  ```
* **Ausschlüsse:**
  - `tags->>'amenity' IN ('school', 'college', 'kindergarten')`
  - Wohnheime und Nebengebäude: `tags->>'building' IN ('dormitory', 'residential')`.

#### E. `stadium`
* **Einschluss:**
  ```sql
  WHERE tags->>'leisure' = 'stadium'
  ```
* **Ausschlüsse:**
  - `tags->>'leisure' IN ('pitch', 'sports_centre', 'track', 'fitness_centre')`.

#### F. `mall`
* **Einschluss:**
  ```sql
  WHERE tags->>'shop' = 'mall'
  ```
* **Ausschlüsse:**
  - Einzelhandelsgeschäfte innerhalb einer Mall: Objekte mit `shop != 'mall'`, auch wenn sie innerhalb des Mall-Polygons liegen.

---

## 6. Ausschlussfilter & Lifecycle-Gate (Globale Negativkriterien)

Ein Objekt wird **unter keinen Umständen** in die Parquet-Datei übernommen, wenn mindestens eines der folgenden Ausschlusskriterien zutrifft:

### 6.1 Status & Lifecycle (Historisch, Inaktiv, Geplant)
1. **Explizite Inaktivität:**
   - `disused = 'yes'` oder `disused IS NOT NULL`
   - `abandoned = 'yes'` oder `abandoned IS NOT NULL`
   - `demolished = 'yes'` oder `demolished IS NOT NULL`
   - `razed IS NOT NULL` oder `removed IS NOT NULL`
   - `operational_status IN ('closed', 'out_of_service')`
   - `end_date IS NOT NULL`
2. **Lifecycle Prefix-Tags:**
   - Jedes Objekt, dessen Primärtag ein Lifecycle-Präfix trägt:
     - `disused:aeroway`, `abandoned:railway`, `demolished:building`
     - `construction:*`, `proposed:*`, `planned:*`

### 6.2 Namenspflicht (Keine namenlosen Landmarken)
- Landmarken und High-Priority POIs erfordern zwingend eine lesbare Bezeichnung.
- Ein Objekt wird **verworfen**, wenn **alle** folgenden Felder `NULL` oder leer sind:
  - `name`, `name:*`, `official_name`, `short_name`, `int_name`, `brand`.

### 6.3 Untereinheiten-Filter (Subunit Filtering)
Objekte mit folgenden Werten im Tagging dürfen niemals als eigenständige Haupt-Feature-Class extrahiert werden:
```text
bar, cafe, restaurant, fast_food, shop, lounge, gate, terminal,
parking, parking_space, training, academy, office, ticket,
security, platform, stop_position, check-in, baggage_claim
```

---

## 7. Tag-Projektion im `tags` JSON-Feld

Um Dateigröße und Speicherbedarf zu minimieren, werden Roh-Tags upstream gefiltert. Es werden ausschließlich jene Tags in das JSON-Objekt übernommen, die für Lokalisierung, Namensfindung, Identifikation, Adressverknüpfung und Source-Fusion downstream benötigt werden:

```json
{
  "name": "München Hauptbahnhof",
  "name:en": "Munich Central Station",
  "name:de": "München Hauptbahnhof",
  "alt_name": "München Hbf",
  "official_name": "München Hauptbahnhof",
  "short_name": "München Hbf",
  "int_name": "Munich Central Station",
  "wikidata": "Q254546",
  "wikipedia": "de:München Hauptbahnhof",
  "brand": "DB",
  "operator": "DB InfraGO AG",
  "railway": "station",
  "uic_ref": "8000261",
  "ibnr": "8000261",
  "ref": "8000261",
  "addr:street": "Bayerstraße",
  "addr:housenumber": "10a",
  "addr:postcode": "80335",
  "addr:city": "München",
  "wheelchair": "yes",
  "opening_hours": "24/7"
}
```

### Whitelist der projizierten Tags:
- **Namen & Sprachvarianten:** `name`, `name:*` (z. B. `name:en`, `name:de`, `name:fr`), `alt_name`, `official_name`, `short_name`, `old_name`, `int_name`, `nat_name`, `loc_name`.
- **Identifikatoren & Cross-References:** `wikidata`, `wikipedia`, `brand:wikidata`, `operator:wikidata`, `iata`, `icao`, `ref`, `uic_ref`, `ibnr`, `network`.
- **Typisierung & Bauwerk:** `aeroway`, `railway`, `amenity`, `tourism`, `historic`, `leisure`, `shop`, `public_transport`, `station`, `building`, `landuse`.
- **Betreiber & Marke:** `brand`, `operator`.
- **Postalische Adressangaben:** `addr:street`, `addr:housenumber`, `addr:postcode`, `addr:city`, `addr:country`.
- **Attribute & Barrierefreiheit:** `wheelchair`, `opening_hours`, `website`, `phone`, `level`, `access`.

---

## 8. Territoriale Zuordnung & Küstenpuffer (Coastal Snapping)

### 8.1 Ländercode-Zuweisung (`country_code`)
- Jedes Feature wird primär über den Schnitt mit den nationalen Grenzpolygonen (`admin_level = 2`) dem entsprechenden ISO-3166-1-Code zugeordnet.
- **Problemfall Offshore- & Küsteninfrastruktur:**
  - Bedeutende Flughäfen und Terminals liegen häufig auf Poldern, künstlichen Inseln oder ins Meer ragenden Aufschüttungen (z. B. Nizza NCE, Kansai KIX, Hongkong HKG, Genua GOA).
  - Werden diese nur gegen strikte Landgrenzen geschnitten, fallen sie ins Meer und werden verworfen.
- **Anforderung:**
  - Beim räumlichen Schnitt mit der Ländergrenze muss ein **maritimer Puffer von mindestens 5 Kilometern (ca. 0,05°)** auf die Küstenlinie angewendet werden.
  - Dadurch ist sichergestellt, dass Hafenanlagen und Küstenflughäfen vollständig dem jeweiligen Staat zugeordnet werden.

---

## 9. Qualitätssicherung & Build-Gates (Upstream Validation)

Der Upstream-Build-Prozess muss vor dem Bereitstellen der Artefakte automatisierte Prüfungen durchlaufen. Bei Verletzung bricht der Erstellungsprozess mit Fehler ab:

```text
Build-Pipeline:
[OSM PBF] ──> Filterung ──> Deduplizierung ──> Point-on-Surface ──> GeoParquet
                                                                        │
                                                                 Quality-Gates:
                                                                 ├─ Schema-Check
                                                                 ├─ Zero-NULL Coord
                                                                 ├─ Point-in-Footprint
                                                                 ├─ Name-Completeness
                                                                 └─ Zero-Disused Check
```

1. **Null-Toleranz bei Koordinaten:**
   ```sql
   SELECT count(*) FROM parquet_scan('osm-pois-*.parquet')
   WHERE geom IS NULL OR ST_IsEmpty(geom) OR isnan(ST_X(geom)) OR isnan(ST_Y(geom));
   -- Erwartung: 0
   ```
2. **Point-in-Footprint Verifikation:**
   ```sql
   SELECT count(*) FROM parquet_scan('osm-pois-*.parquet')
   WHERE footprint IS NOT NULL AND NOT ST_Intersects(footprint, geom);
   -- Erwartung: 0
   ```
3. **Vollständigkeit der Namen:**
   ```sql
   SELECT count(*) FROM parquet_scan('osm-pois-*.parquet')
   WHERE tags->>'name' IS NULL 
     AND tags->>'official_name' IS NULL 
     AND tags->>'brand' IS NULL;
   -- Erwartung: 0
   ```
4. **Lifecycle-Freiheit:**
   ```sql
   SELECT count(*) FROM parquet_scan('osm-pois-*.parquet')
   WHERE tags->>'disused' = 'yes' 
      OR tags->>'abandoned' = 'yes'
      OR tags->>'operational_status' = 'closed';
   -- Erwartung: 0
   ```
5. **JSON-Validität:**
   Alle Einträge in `tags` müssen fehlerfrei als JSON geparst werden können.

---

## 10. Dateinamen & Bereitstellung

- **Namenskonvention:** `osm-pois-{CC}.parquet`
  - Beispiele: `osm-pois-DE.parquet`, `osm-pois-FR.parquet`, `osm-pois-MC.parquet`.
  - Bei föderalen Großstaaten oder Territorien wird die Datei analog zu den bestehenden `admin-polygons-{CC}.parquet`- und `osm-facilities-{CC}.parquet`-Artefakten abgelegt.
- **Bereitstellungsort:**
  - Distribution via Release-Server / GitHub Release / S3-Bucket im Standard-Verzeichnis `data/osm-pois/`.
