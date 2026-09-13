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

### 4. Dual-Panel UI Architecture
To prevent vertical crowding and ensure deep inspection of rich Overture schema fields:
* **Header Bar**:
  * Displays real-time connection status, viewport zoom, POI render count, and a persistent **📦 File & Compiler Version Badge** (`compiler_version` • export date / age) that jumps directly to dataset provenance on click.
* **Left Panel (Controls & Dataset)**:
  1. **Quick Extent Jump**: One-click bounds fitting (`Fit Dataset`) and shortcuts to major cities.
  2. **Filters**: Real-time filtering by POI name, primary category (top 50 categories), **POI Quality / Minimum Confidence** (Top Quality ≥85%, High ≥70%, Standard ≥55%, Basic ≥40%, Low/Stale <40%), and **Operational Attributes** (With Hours, With Wheelchair, With Cuisine, With Brand, With Contact).
  3. **Active Dataset & Provenance**: Live row count, file size, dataset age, and comprehensive Parquet KV metadata (compiler, compiler version, export timestamp, country code badge, schema, ODbL and CC-BY-4.0 licenses, and attribution links).
  4. **OSM Basemap & Gap Detection**: Opacity controls and the `⚡ Blink Overlay` toggle.
  5. **Level of Detail (LOD) Rules**: Configurable zoom thresholds and sample limits.
* **Right Panel (POI Details Inspector)**:
  * Dedicated floating panel that automatically opens when a POI circle marker is clicked.
  * **POI Quality & Confidence**: Displays the calculated upstream confidence score (0.10 - 0.99) with color-coded rating tier, animated progress bar, and contributing quality signal badges (Hours, Contact, Address, Wheelchair, Brand, Mature revision).
  * **Opening Hours**: Formatted opening hours block with automatic `Open 24/7` detection.
  * **Operational & Accessibility Depth**: Wheelchair accessibility badge (Accessible, Limited, Not accessible, Designated), payment methods chips (Cash, Cards, Contactless), cuisine tags, floor/level, operator, and delivery/takeaway indicators.
  * **Brand & Identity**: Primary brand name and direct links to Wikidata entity records.
  * **Core Schema & Provenance**: Name, primary/basic categories, operating status, OSM revision (`v14`), last edit timestamp, address, coordinates, phone, website, email, and direct links to the OSM object and its version history.
  * Can be toggled independently via the `POI Details` button in the header.

### 5. Stale File Handle & Recompilation Diagnostics
* If a `.parquet` file is recompiled or replaced on disk while the viewer is active, the browser's cached file handle becomes invalid (`No magic bytes found`).
* The viewer automatically detects this error condition and displays a clear on-screen banner prompting the user to re-drop the updated file or refresh the page (`F5`), preventing silent query failures.
