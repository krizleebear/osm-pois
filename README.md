# osm-pois

Automated worldwide OpenStreetMap (OSM) to **Overture Places-compatible GeoParquet** compiler pipeline.

Transforms cached OSM `.osm.pbf` extracts into cloud-optimized GeoParquet files (`places.parquet`) matching the official Overture Maps `theme=places/type=place` schema.

## 🎯 Features

- **100% Overture Maps Schema Compatible**: Drop-in replacement for Overture Places in pipelines like [`osm-geocoder`](https://github.com/krizleebear/osm-geocoder).
- **Pure OpenStreetMap Data (ODbL)**: Full provenance, freshly compiled from daily/weekly OSM PBF dumps.
- **2,100+ Category Mappings**: Direct taxonomy mapping from OSM tags (`amenity`, `shop`, `tourism`, `leisure`, `office`, `craft`, `healthcare`, `historic`) to Overture taxonomy categories.
- **Serverless & Fast**: Runs via Docker (`osmium-tool` + `DuckDB Spatial`) directly inside CI/CD runners (Azure Pipelines parallel matrix across 150+ countries/regions).

## 📁 Repository Structure

```
osm-pois/
├── azure-pipelines.yml          # Azure DevOps pipeline definition with parallel country matrix
├── docker/
│   └── osm2parquet/
│       ├── Dockerfile           # Docker image with DuckDB + Spatial extension + osmium-tool
│       ├── entrypoint.sh        # Runner script
│       ├── osmconf.ini          # GDAL OSM driver configuration for POI tags
│       ├── export_pois.sql      # DuckDB SQL mapping into Overture Places GeoParquet
│       └── mappings/
│           ├── overture_categories.csv         # Overture taxonomy hierarchy
│           └── overture_to_osm_categories.csv  # 2,100+ OSM tag to Overture category rules
└── README.md
```

## 🛠️ Building & Testing Locally

### 1. Build the Docker image
```bash
docker build -t ghcr.io/krizleebear/osm2pois:v1.0.0 docker/osm2parquet/
```

### 2. Run conversion on a local PBF
```bash
# Filter POIs with osmium
osmium tags-filter monaco-latest.osm.pbf \
  nwr/amenity nwr/shop nwr/tourism nwr/leisure nwr/office nwr/craft nwr/healthcare nwr/historic nwr/aeroway \
  -o MC_monaco.pois.pbf --overwrite

# Run converter container
docker run --rm \
  -v $(pwd):/data \
  ghcr.io/krizleebear/osm2pois:v1.0.0 \
  /app/entrypoint.sh /data/MC_monaco.pois.pbf /data/places.parquet MC
```
