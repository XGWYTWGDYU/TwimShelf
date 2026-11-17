# TwimShelf Linux server: the Rust core and the web app on one port.
#
#   ./build.sh docker            (passes the pinned Rust and Node versions, see below)
#   docker run -d -p 2778:2778 -v /path/to/data:/data twimshelf
#
# /app holds the program (server + web app), /data everything it keeps (see docker/README.md).
# The version is config.yaml's, as for every other build (./build.sh docker builds and saves it).
# The tools are the repository's pinned ones: RUST_VERSION from rust-toolchain.toml, NODE_VERSION
# from .node-version (docker build --build-arg RUST_VERSION=… --build-arg NODE_VERSION=… by hand).

ARG RUST_VERSION
ARG NODE_VERSION

# ---- the server: the core with HEIC/AVIF, built from pinned sources ----
FROM rust:${RUST_VERSION}-bookworm AS server
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build nasm meson pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY config.yaml Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY core core
COPY server server
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    export TL_VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' config.yaml)" && \
    cargo build -p tl-server --release --locked && cp target/release/twimshelf-server /twimshelf-server

# ---- the web app: the React front end (web/) ----
FROM node:${NODE_VERSION}-bookworm-slim AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
COPY web/packages/core/package.json packages/core/package.json
COPY web/app/package.json app/package.json
COPY web/electron/package.json electron/package.json
# the desktop app's packages (Electron) are not needed here
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund --workspace app --include-workspace-root=false --ignore-scripts
COPY web/tsconfig.base.json ./
COPY web/packages packages
COPY web/app app
RUN npm run build -w app

# ---- what runs ----
FROM debian:bookworm-slim
ARG VERSION=dev
LABEL org.opencontainers.image.title="TwimShelf" \
      org.opencontainers.image.description="TwimShelf Linux server: the library and the web app" \
      org.opencontainers.image.source="https://github.com/XGWYTWGDYU/TwimShelf" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tini ffmpeg && rm -rf /var/lib/apt/lists/*
COPY --from=server /twimshelf-server /app/twimshelf-server
# `docker exec -it <container> twimshelf passwd`
RUN ln -s /app/twimshelf-server /usr/local/bin/twimshelf
COPY --from=web /src/web/app/dist /app/web
COPY docker/entrypoint.sh /app/entrypoint.sh
ENV TL_DATA=/data TL_WEB=/app/web TL_PORT=2778
VOLUME /data
EXPOSE 2778
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD ["/app/twimshelf-server", "--health"]
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
