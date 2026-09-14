# Analyse & Upstream-Feedback: `krizleebear/osm-pois` (Release `20260913.5`)

Basierend auf dem ersten vollständigen Durchlauf von Deutschland (`DE`) im `osm-geocoder` mit dem neuen POI-Provider `osm-pois` wurden die extrahierten Daten (`DE_germany.places.parquet`, 2.095.576 Datensätze) analysiert.

Folgende Punkte bieten signifikantes Verbesserungspotenzial für zukünftige Releases von `osm-pois`.

---

## 1. Alternativnamen fehlen vollständig (`names.rules` ist bei 100% `NULL`)

### Befund
Im Overture-kompatiblen Schema werden Alternativ- und Zusatznamen über das Array `names.rules` abgebildet. In `DE_germany.places.parquet` ist dieses Feld bei **allen 2.095.576 POIs `NULL`**:

```sql
SELECT count(*) FROM 'DE_germany.places.parquet' WHERE names.rules IS NOT NULL;
-- Ergebnis: 0
```

### Problem & Auswirkungen
* In OpenStreetMap existieren flächendeckend wertvolle Namensvarianten:
  * `alt_name=*` (Alternative Namen, Abkürzungen)
  * `official_name=*` (Vollständige offizielle Bezeichnung)
  * `short_name=*` (Kurzformen)
  * `loc_name=*` / `reg_name=*` (Lokale / regionale Bezeichnungen)
  * `int_name=*` (Internationaler Name)
* Diese Informationen gehen beim Export derzeit komplett verloren. Im Geocoder führt dies zu einer spürbar schlechteren Auffindbarkeit von POIs (z.B. wenn Nutzer nach geläufigen Abkürzungen oder umgangssprachlichen Namen suchen).

### Empfehlung für Upstream
Mapping der entsprechenden OSM-Tags in das Struct-Array `names.rules`:
* `alt_name` $\rightarrow$ `{'variant': 'alternate', 'value': ...}`
* `official_name` $\rightarrow$ `{'variant': 'official', 'value': ...}`
* `short_name` $\rightarrow$ `{'variant': 'short', 'value': ...}`
* `loc_name` $\rightarrow$ `{'variant': 'local', 'value': ...}`

---

## 2. Sekundärkategorien ungenutzt (`categories.alternate` ist überall leer)

### Befund
Die Spalte `categories.alternate` ist bei **100% der Datensätze** eine leere Liste (`[]`):

```sql
SELECT count(*) FROM 'DE_germany.places.parquet' WHERE len(categories.alternate) > 0;
-- Ergebnis: 0
```

### Problem & Auswirkungen
In OpenStreetMap besitzen viele Einrichtungen mehrere funktionale Rollen oder Spezialisierungen, die über Kombinations-Tags abgebildet werden:
* `shop=bakery` + `amenity=cafe` (Bäckerei mit Café-Betrieb)
* `amenity=restaurant` + `cuisine=pizza;italian` (Gastronomie mit spezifischer Küche)
* `amenity=pharmacy` + `dispensing=yes`
* `leisure=sports_centre` + `sport=swimming;fitness`

Aktuell wird nur ein einzelner primärer Tag in `categories.primary` übernommen.

### Empfehlung für Upstream
* Relevante Sekundärtags, Mehrfachwerte und `cuisine=*` in das Array `categories.alternate` überführen.
* Dadurch können Downstream-Konsumenten Einrichtungen präziser filtern und kategorisieren.

---

## 3. Social-Media-Links fehlen (`socials` ist überall leer)

### Befund
Während Kontaktdaten wie `websites` (670.955 Einträge), `phones` (531.604 Einträge) und `emails` (230.002 Einträge) gut befüllt sind, ist das Feld `socials` bei **allen 2.095.576 Datensätzen leer**:

```sql
SELECT count(*) FROM 'DE_germany.places.parquet' 
WHERE socials IS NOT NULL AND len(socials) > 0;
-- Ergebnis: 0
```

### Empfehlung für Upstream
OSM-Tags für soziale Netzwerke in das `socials`-Array übernehmen:
* `contact:facebook=*` / `facebook=*`
* `contact:instagram=*` / `instagram=*`
* `contact:twitter=*` / `contact:x=*`
* `contact:linkedin=*`
* `contact:youtube=*`

---

## 4. Reine Autobahn-Rastplätze (`highway=rest_area` ohne Gebäude)

### Befund
Autobahn-Rastplätze, die in OSM als Flächenpolygon kartiert sind, aber über keine Gastronomie oder Gebäude verfügen (z.B. reine Parkplätze mit Tischen, `highway=rest_area` mit `toilets=no`, wie der *Rastplatz Vogelherd* an der A 3), werden derzeit nicht als POIs extrahiert.

### Problem & Auswirkungen
* Downstream-Geocoder und Navigationssysteme führen Autobahn-Rastanlagen oft als Facility-Bereiche.
* Wenn eine Facility-Fläche keinerlei innere POIs oder Zugangspunkte enthält, wird sie in der Regel als inhaltsleer verworfen.

### Empfehlung für Upstream
* Prüfen, ob `highway=rest_area` (oder darin liegende `amenity=parking` / Parkflächen) standardmäßig als POI mit der Kategorie `rest_area` bzw. `parking` in den Parquet-Datensatz aufgenommen werden können.

---

## Zusammenfassung: Spaltenabdeckung in `DE_germany.places.parquet`

| Spalte / Eigenschaft | Vorhandene Datensätze | Abdeckung (%) | Upstream-Handlungsbedarf |
| :--- | :--- | :--- | :--- |
| `id` / `geometry` | 2.095.576 | 100,0% |  Optimal |
| `names.primary` | 2.095.576 | 100,0% |  Optimal |
| `names.common` (Übersetzungen) | 43.551 | 2,1% |  Funktioniert |
| **`names.rules` (Alternativnamen)** | **0** | **0,0%** | 🚨 **Dringend: `alt_name`, `official_name` mappen** |
| `categories.primary` | 2.095.576 | 100,0% |  Optimal |
| **`categories.alternate`** | **0** | **0,0%** | ⚠️ **Sekundärtags / Cuisine übernehmen** |
| `websites` | 670.955 | 32,0% |  Optimal |
| `phones` | 531.604 | 25,4% |  Optimal |
| `emails` | 230.002 | 11,0% |  Optimal |
| **`socials`** | **0** | **0,0%** | ⚠️ **`contact:facebook/instagram` mappen** |
| `brand.wikidata` / `brand.names` | 180.300 / 220.023 | 8,6% / 10,5% |  Optimal |
| `addresses[].freeform` | 894.747 | 42,7% |  Gut für OSM-Abdeckung |
| `opening_hours` | 629.851 | 30,1% |  Sehr gut |
| `wheelchair` | 526.277 | 25,1% |  Sehr gut |
