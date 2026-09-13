# osm-pois

Automated worldwide OpenStreetMap (OSM) to **Overture Places-compatible GeoParquet** compiler pipeline.

Transforms cached OSM `.osm.pbf` extracts into cloud-optimized GeoParquet files (`places.parquet`) matching the official Overture Maps `theme=places/type=place` schema.

## 🎯 Features

- **100% Overture Maps Schema Compatible**: Drop-in replacement for Overture Places in pipelines like [`osm-geocoder`](https://github.com/krizleebear/osm-geocoder).
- **Zero New Docker Images**: Directly reuses the existing, production-proven `ghcr.io/krizleebear/osm2parquet:v1.0.9` container (equipped with `DuckDB CLI` + `spatial` extension + `osmium-tool`).
- **Pure OpenStreetMap Data (ODbL)**: Full provenance, freshly compiled from daily/weekly OSM PBF dumps.
- **2,100+ Category Mappings**: Direct taxonomy mapping from OSM tags (`amenity`, `shop`, `tourism`, `leisure`, `office`, `craft`, `healthcare`, `historic`) to Overture taxonomy categories.
- **Serverless & Fast**: Runs via Azure Pipelines parallel matrix across 150+ countries/regions.

## 📁 Repository Structure

```
osm-pois/
├── azure-pipelines.yml          # Azure DevOps pipeline definition with parallel country matrix
├── config/
│   └── osmconf.ini              # GDAL OSM driver configuration for POI tags
├── mappings/
│   ├── overture_categories.csv         # Overture taxonomy hierarchy
│   └── overture_to_osm_categories.csv  # 2,100+ OSM tag to Overture category rules
├── scripts/
│   ├── entrypoint.sh            # Runner script for DuckDB conversion
│   ├── export_pois.sql          # Orchestrator for DuckDB conversion & Parquet export
│   └── sql/                     # Modular DuckDB SQL components
│       ├── 01_taxonomy.sql      # Taxonomy & category mapping rules loader
│       ├── 02_macros.sql        # Reusable macros (names, brand, addresses, filters)
│       └── 03_categorization.sql# POI category resolution (Single Source of Truth)
└── README.md
```

## 🛠️ Testing Locally

You can test the conversion locally using the existing `osm2parquet` image:

```bash
# 1. Filter POIs with osmium
osmium tags-filter monaco-latest.osm.pbf \
  nwr/amenity nwr/shop nwr/tourism nwr/leisure nwr/office nwr/craft nwr/healthcare nwr/historic nwr/aeroway \
  -o MC_monaco.pois.pbf --overwrite

# 2. Run conversion using existing osm2parquet image
docker run --rm \
  -v $(pwd):/workspace \
  -w /workspace \
  ghcr.io/krizleebear/osm2parquet:v1.0.9 \
  ./scripts/entrypoint.sh MC_monaco.pois.pbf places.parquet MC
```

## 📜 Embedded Parquet Metadata & Provenance

Every generated `.places.parquet` file contains comprehensive provenance and attribution metadata embedded at both the file and record levels:

### 1. Parquet File-Level Key-Value Metadata
Inspect metadata in the Parquet file footer via DuckDB:

```sql
SELECT key, CAST(value AS VARCHAR) AS val 
FROM parquet_kv_metadata('MC_monaco.places.parquet');
```

| Key | Value / Description |
|-----|---------------------|
| `source` | `OpenStreetMap` |
| `origin` | `OpenStreetMap (https://www.openstreetmap.org)` |
| `dataset` | `OpenStreetMap POIs (Overture Places Schema Compatible)` |
| `attribution` | `© OpenStreetMap contributors` |
| `attribution_url` | `https://www.openstreetmap.org/copyright` |
| `license` | `ODbL-1.0 (https://opendatacommons.org/licenses/odbl/)` |
| `license_url` | `https://opendatacommons.org/licenses/odbl/` |
| `copyright` | `Data © OpenStreetMap contributors, licensed under Open Data Commons Open Database License 1.0 (ODbL)` |
| `schema` | `Overture Maps theme=places / type=place` |
| `schema_url` | `https://overturemaps.org/schema/` |
| `schema_license` | `CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/)` |
| `schema_license_url` | `https://creativecommons.org/licenses/by/4.0/` |
| `schema_attribution` | `Schema specification © Overture Maps Foundation, licensed under Creative Commons Attribution 4.0 International (CC-BY-4.0)` |
| `compiler` | `osm-pois (https://github.com/krizleebear/osm-pois)` |
| `compiler_version`| Build number or git commit hash |
| `country_code` | Two-letter ISO country code (e.g. `MC`, `DE`) |
| `exported_at` | ISO 8601 generation timestamp (UTC) |
| `geo` | OGC GeoParquet standard metadata (bounding box, geometry encoding) |

### 2. Record-Level Provenance & Versioning
Each POI row conforms strictly to the Overture Places schema and retains original OSM versioning:
- **`version`**: The exact OpenStreetMap feature version number (`@version`).
- **`sources`**:
  ```json
  [{
    "property": "",
    "dataset": "OpenStreetMap",
    "license": "ODbL-1.0",
    "record_id": "osm:node/25191432",
    "update_time": "2023-10-24T17:35:37Z",
    "confidence": 1.0
  }]
  ```

---

## 🙏 Attribution & Licensing

### OpenStreetMap (ODbL 1.0)
This project compiles data derived from **OpenStreetMap**, made available under the **Open Database License (ODbL) 1.0**:
- **Data Copyright**: © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright)
- **License**: [Open Data Commons Open Database License 1.0 (ODbL)](https://opendatacommons.org/licenses/odbl/)

#### Downstream Attribution Requirements
If you use, redistribute, display, or build services using the GeoParquet files generated by this pipeline (e.g. in geocoders, applications, or downstream databases), you **must** credit OpenStreetMap:
> **"Data © OpenStreetMap contributors, available under the Open Database License (ODbL)."**

When displaying or distributing electronically, you must include hyperlinked text pointing to:
- [https://www.openstreetmap.org/copyright](https://www.openstreetmap.org/copyright)
- [https://opendatacommons.org/licenses/odbl/](https://opendatacommons.org/licenses/odbl/)

If you alter or build upon OpenStreetMap data and distribute the result as a derivative database, you must distribute that derivative database under the ODbL as well (Share-Alike).

### Taxonomy & Category Mappings (MIT)
The initial mapping tables (`mappings/overture_to_osm_categories.csv` and `mappings/overture_categories.csv`) are derived from the [Cadence Maps](https://gitlab.com/geometalab/bafs25-cadencemaps) project (OST / Eastern Switzerland University of Applied Sciences, by Fadil Smajilbasic, Matthias Hersche, Nils Robin-Grob) and are licensed under the [MIT License](mappings/README.md).

### Code License (MIT)
The pipeline code, configurations, and conversion scripts are licensed under the [MIT License](LICENSE.md) © 2025-2026 Christian Leberfinger.

### Overture Maps Foundation Schema (CC-BY-4.0)
The target schema (`theme=places / type=place`) and category taxonomy concepts follow the open specifications of the [Overture Maps Foundation](https://overturemaps.org/):
- **Schema Specification**: [Overture Maps Schema](https://github.com/OvertureMaps/schema) ([docs.overturemaps.org/schema](https://docs.overturemaps.org/schema/))
- **Schema License**: [Creative Commons Attribution 4.0 International (CC-BY-4.0)](https://creativecommons.org/licenses/by/4.0/)
- **Attribution**: Schema specification © [Overture Maps Foundation](https://overturemaps.org/), licensed under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).

> [!NOTE]
> This pipeline compiles OpenStreetMap data into the Overture schema as a compatible drop-in target format. The underlying data remains OpenStreetMap (ODbL 1.0), while the schema specification itself is governed by CC-BY-4.0.

### Trademark & Non-Affiliation Disclaimer
"OpenStreetMap" is a registered trademark of the OpenStreetMap Foundation. "Overture Maps" is a trademark of the Joint Development Foundation.

This project is an independent open-source tool and is **not** affiliated with, endorsed by, or sponsored by either the OpenStreetMap Foundation or the Overture Maps Foundation.

