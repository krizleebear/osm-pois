# Unified Dev Container for osm-pois
# Environment: Ubuntu 26.04, DuckDB CLI + Spatial, Osmium Tool, Git, Opencode, Antigravity CLI (agy)
# Timezone: Europe/Berlin
# User: ubuntu (UID 1000)
FROM ubuntu:26.04

USER root

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Europe/Berlin \
    DEBIAN_FRONTEND=noninteractive

# 1. Base system tools, timezone & utilities
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      ripgrep \
      rsync \
      tar \
      unzip \
      tzdata \
      osmium-tool \
      xclip \
      xsel \
      wl-clipboard && \
    ln -fs /usr/share/zoneinfo/Europe/Berlin /etc/localtime && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    rm -rf /var/lib/apt/lists/*

# 2. Install DuckDB CLI + Spatial Extension (Multi-Arch)
RUN set -eux; \
    ARCH="$(uname -m)"; \
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        DUCKDB_URL="https://github.com/duckdb/duckdb/releases/download/v1.5.5/duckdb_cli-linux-arm64.zip"; \
    else \
        DUCKDB_URL="https://github.com/duckdb/duckdb/releases/download/v1.5.5/duckdb_cli-linux-amd64.zip"; \
    fi; \
    curl -sSL "$DUCKDB_URL" -o /tmp/duckdb.zip && \
    unzip -q /tmp/duckdb.zip -d /usr/local/bin && \
    chmod 755 /usr/local/bin/duckdb && \
    rm /tmp/duckdb.zip && \
    duckdb -c "INSTALL spatial; LOAD spatial;" && \
    cp -r /root/.duckdb /tmp/.duckdb-ext-cache

# 3. Install AI Agent CLIs (opencode & agy)
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path && \
    mv /root/.opencode/bin/opencode /usr/local/bin/opencode && \
    chmod 755 /usr/local/bin/opencode && \
    rm -rf /root/.opencode

ARG CACHEBUST_AGY=""
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin && \
    chmod 755 /usr/local/bin/agy

# 4. Install GitHub CLI (gh 2.98.0, Multi-Arch)
RUN set -eux; \
    ARCH="$(uname -m)"; \
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        GH_ARCH="linux_arm64"; \
    else \
        GH_ARCH="linux_amd64"; \
    fi; \
    GH_VERSION="2.98.0"; \
    curl -sSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_${GH_ARCH}.tar.gz" -o /tmp/gh.tar.gz && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    mv /tmp/gh_${GH_VERSION}_${GH_ARCH}/bin/gh /usr/local/bin/gh && \
    chmod 755 /usr/local/bin/gh && \
    rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_VERSION}_${GH_ARCH}

RUN install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh && \
    install -d -o ubuntu -g ubuntu \
      /home/ubuntu/.config/opencode \
      /home/ubuntu/.local/share/opencode \
      /home/ubuntu/.local/state/opencode \
      /home/ubuntu/.config/antigravity \
      /home/ubuntu/.local/share/antigravity \
      /home/ubuntu/.local/state/antigravity \
      /home/ubuntu/.config/gh \
      /home/ubuntu/.gemini \
      /home/ubuntu/.cache

ENV HOME=/home/ubuntu

# Copy pre-installed DuckDB extensions (spatial) to ubuntu user
RUN cp -r /tmp/.duckdb-ext-cache /home/ubuntu/.duckdb && \
    chown -R ubuntu:ubuntu /home/ubuntu/.duckdb && \
    rm -rf /tmp/.duckdb-ext-cache && \
    printf "INSTALL spatial;\nLOAD spatial;\n" > /home/ubuntu/.duckdbrc && \
    chown ubuntu:ubuntu /home/ubuntu/.duckdbrc && \
    sed -i 's|\\u@\\h: \\w|[osm-pois] \\w|g' /home/ubuntu/.bashrc /root/.bashrc

# 5. Install clipboard bridge shims for macOS / Docker host clipboard integration
COPY .devcontainer/bin/* /usr/local/bin/
RUN chmod +x /usr/local/bin/xclip /usr/local/bin/wl-paste

USER ubuntu
WORKDIR /app

ENV GIT_CONFIG_PARAMETERS="'safe.directory=/app'"

ENTRYPOINT ["/bin/bash"]
