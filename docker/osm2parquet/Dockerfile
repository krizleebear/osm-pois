FROM debian:bookworm-slim

ARG TARGETARCH

# Install system dependencies required by GDAL OSM driver and DuckDB spatial extension.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    ca-certificates \
    libgdal-dev \
    osmium-tool \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install DuckDB CLI — pinned version for reproducibility
ARG DUCKDB_VERSION=v1.5.5
RUN curl -fsSL \
    "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${TARGETARCH}.zip" \
    -o /tmp/duckdb.zip \
    && unzip /tmp/duckdb.zip -d /usr/local/bin \
    && rm /tmp/duckdb.zip \
    && chmod +x /usr/local/bin/duckdb

WORKDIR /app
ENV HOME=/app

# Pre-install and cache DuckDB spatial extension at build time.
RUN duckdb -c "INSTALL spatial;"

COPY osmconf.ini export_pois.sql entrypoint.sh /app/
COPY mappings/ /app/mappings/
RUN chmod +x /app/entrypoint.sh

# Grant 777 permissions to /app so Azure DevOps runner user (vsts_azpcontainer) can run
RUN chmod -R 777 /app

LABEL org.opencontainers.image.source="https://github.com/krizleebear/osm-pois"
LABEL org.opencontainers.image.description="DuckDB spatial converter for OSM POI to Overture-compatible GeoParquet exports"

CMD ["/bin/bash"]
