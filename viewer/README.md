# OSM-POIS Gap Analysis & Quality HTML Viewer

An interactive map viewer designed to visually inspect, validate, and identify coverage gaps in compiled Overture-compatible GeoParquet POI datasets (`*.places.parquet`) against the OpenStreetMap (OSM) standard basemap.

---

## 🚀 Quickstart

Because modern web browsers restrict Web Workers and WebAssembly when running directly from `file://` protocols, serve the directory using any static web server:

```bash
# Using Python (on your host machine)
python3 -m http.server 8080

# Or using npx
npx serve .

# Or using Caddy / Live Server extension in VS Code
```

Then open `http://localhost:8080/viewer/` in your browser.

---

## 🎯 Features

### 1. Zero Backend / Pure Client-Side DuckDB-Wasm
* Powered by `@duckdb/duckdb-wasm` directly in your browser.
* Reads `.places.parquet` files directly via **Full-Window Drag & Drop** (drop anywhere on the page) or file picker using the Browser FileReader protocol without uploading your files anywhere.
* Spatial viewport bounding-box queries execute in milliseconds using column projection and row-group predicate pushdown on Parquet metadata (`bbox.xmin`, `bbox.xmax`, `bbox.ymin`, `bbox.ymax`).

### 2. Zoom-Adaptive Density & Level-of-Detail (LOD)
To ensure the browser stays responsive even when inspecting massive datasets (like `DE_germany.places.parquet` with 1.62+ million POIs):
* **Macro View (`Zoom < 12`)**: POI points are hidden with an on-screen hint to prevent downloading or rendering hundreds of thousands of items simultaneously.
* **Overview Mode (`Zoom 12 - 15`)**: Renders a representative sample of POIs (default max: 500, configurable) to give an accurate sense of distribution without lag.
* **Full Detail Mode (`Zoom ≥ 16`)**: Renders **every single POI** in the current viewport (up to 10,000). This enables seamless 1:1 comparison against building footprints and street-level OSM features.

### 3. Visual Gap Detection Against OSM Basemap
* **OSM Standard Basemap**: Shows native OpenStreetMap styling, icons, and labels (shops, cafes, restaurants, pharmacies, bus stops, benches, etc.).
* **Contrasting POI Overlay**: Compiled GeoParquet POIs are rendered as high-contrast canvas circle markers color-coded by category:
  * 🟠 **Food & Drink**: Restaurants, Cafes, Bakeries, Fast Food, Pubs
  * 🔵 **Shopping / Retail**: Supermarkets, Convenience, Apparel, Electronics
  * 🔴 **Health & Medical**: Hospitals, Pharmacies, Doctors, Dentists
  * 🟣 **Accommodation**: Hotels, Motels, Hostels
  * 🟡 **Arts & Culture**: Museums, Monuments, Artwork, Cinemas
  * 🟢 **Services & Civic**: Banks, Post Offices, Police, Schools, Churches
  * 🔷 **Transportation**: Stations, Bus Stops, Parking, EV Chargers
* **⚡ Blink Overlay**: Toggles the POI overlay on and off every 500ms to immediately highlight OSM icons on the basemap that lack a corresponding POI marker (gap spotted!).
* **Opacity Sliders**: Fine-tune basemap and POI overlay transparency for side-by-side comparison.

### 4. Interactive Feature Inspection, Versioning & OSM Link
* Clicking on any POI circle marker inspects its Overture schema properties and provenance:
  * `names.primary`
  * `categories.primary` & `basic_category`
  * **OSM Version**: Feature revision number (`v14`)
  * **Last OSM Edit**: UTC timestamp of the last edit (`2023-10-24 17:35:37 UTC`)
  * **Source & License**: `OpenStreetMap (ODbL-1.0)`
  * `operating_status`
  * `addresses` (freeform, postcode, locality)
  * `websites`, `phones`
  * **Direct Links**:
    * Clickable link to OpenStreetMap object (`https://www.openstreetmap.org/node/...` or `way/...`) to view raw source tags.
    * Clickable link to OpenStreetMap version history (`.../history`) to inspect past edits and changesets.

### 5. Dataset Metadata & Provenance Card
* Automatically reads file-level Key-Value metadata from Parquet footers via DuckDB-Wasm:
  * **Compiler Version**: Release build number or git commit hash
  * **Exported Date**: UTC timestamp when the parquet file was compiled
  * **Schema**: Overture Places specification
  * **License & Attribution**: ODbL-1.0 & © OpenStreetMap contributors
  * **Country Code**: ISO country code badge (e.g. `[MC]`, `[DE]`)
