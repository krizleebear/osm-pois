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
│   └── export_pois.sql          # DuckDB SQL mapping into Overture Places GeoParquet
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
