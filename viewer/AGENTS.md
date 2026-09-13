# AGENTS.md — Development Guidelines for the Map Viewer (`viewer/`)

This document defines guidelines, design principles, and technical invariants for agents working on the client-side interactive map viewer (`viewer/index.html`).

---

## 1. Architecture & Core Technologies

* **Engine**: Pure client-side `@duckdb/duckdb-wasm` (no backend server required).
* **Map Renderer**: Leaflet.js with Canvas-backed `L.circleMarker` rendering.
* **Data Format**: Cloud-optimized Overture Places-compatible GeoParquet files (`*.places.parquet`).
* **Ingestion Protocol**:
  * Files are loaded directly into DuckDB-Wasm via `db.registerFileHandle(..., duckdb.DuckDBDataProtocol.BROWSER_FILEREADER, true)`.
  * Spatial viewport queries use column projection and row-group bounding box filtering on `bbox.xmin`, `bbox.xmax`, `bbox.ymin`, and `bbox.ymax`.

---

## 2. Technical Invariants

### 1. DuckDB-Wasm Stale File Handle & Magic Bytes Diagnostics
* **Problem**: When a `.parquet` file is replaced, recompiled, or overwritten on disk while the viewer remains open in the browser, the browser's cached `File` handle becomes stale. Subsequent queries seeking to the end of the file to read Parquet metadata fail with:
  `Invalid Input Error: No magic bytes found at end of file '<filename>'`
* **Invariant**:
  * Never let viewport query failures fail silently or only log to `console.error`.
  * All DuckDB query catch blocks in the viewer must detect this specific error pattern (`err.message.includes('magic bytes')` or `err.message.includes('No magic bytes found')`).
  * When detected, immediately update the UI status indicator (`statusDot.className = 'status-dot warning'`, status text) and display a user-facing banner explaining that the file was modified on disk and prompting the user to re-drop the file or refresh the page (`F5`).

### 2. UI Layout: Dual-Panel Architecture
To prevent vertical crowding and ensure seamless inspection of rich Overture schema fields, the viewer strictly follows a **Dual-Panel Architecture**:

1. **Left Panel (`#sidebar`) — Controls & Dataset**:
   * Fixed logical section hierarchy:
     1. **Quick Extent Jump** (`Fit Dataset` highlighted, plus city jump shortcuts)
     2. **Filters** (`Filter by Name...` text input, Category dropdown)
     3. **Active Dataset & Metadata** (Dataset name, total POI count, and the Parquet KV metadata card with compiler version, export timestamp, schema, ODbL license, attribution, and country code)
     4. **OSM Basemap & Gap Detection** (Basemap selector, opacity sliders, blink overlay button)
     5. **Level of Detail (LOD) Rules** (Full detail zoom threshold slider, overview max POIs slider)
   * **No Redundant In-Panel Drop Zones or Presets**:
     * In-panel drop boxes and preset selection dropdowns are omitted to preserve vertical space.
     * File loading is handled globally via full-window drag-and-drop (`fullDropOverlay`) or the header `📂 Load Parquet` button.
   * **No Bulky Legend Blocks**: Category legend grids are omitted from the panel; circle markers retain their category colors.

2. **Right Panel (`#inspectorPanel`) — POI Details Inspector**:
   * Positioned on the top-right (`.sidebar-right`).
   * Displays an initial placeholder when no feature is selected.
   * Automatically opens (`classList.remove('collapsed')`) whenever a POI marker is clicked on the map.
   * Displays full schema attributes: Name, Category, Basic Category, Operating Status, OSM Version (`v14`), Last OSM Edit timestamp, Source & License, Address, Coordinates, Website, Phone, and direct links to the OSM object and its version history.
   * Can be toggled independently via the header button `POI Details` and closed via `✕`.
