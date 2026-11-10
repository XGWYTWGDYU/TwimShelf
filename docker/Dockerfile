# TwimShelf Linux server: the Rust core and the web app on one port.
#
#   docker build -f docker/Dockerfile -t twimshelf .
#   docker run -d -p 2778:2778 -v /path/to/data:/data twimshelf
#
# /app holds the program (server + web app), /data everything it keeps (see docker/README.md).
# The version is config.yaml's, as for every other build (./build.sh docker builds and saves it).

ARG FLUTTER_VERSION=3.47.8

# ---- the server: the core with HEIC/AVIF, built from pinned sources ----
FROM rust:1-bookworm AS server
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build nasm meson pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY config.yaml config.yaml
COPY core core
COPY server server
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/server/target \
    export TL_VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' config.yaml)" && \
    cd server && cargo build --release --locked && cp target/release/twimshelf-server /twimshelf-server

# ---- the web app: the Flutter app built for browsers ----
FROM debian:bookworm-slim AS web
ARG FLUTTER_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /flutter
ENV PATH=/flutter/bin:$PATH FLUTTER_SUPPRESS_ANALYTICS=true
RUN flutter config --no-analytics --enable-web >/dev/null && flutter precache --web
WORKDIR /src
COPY flutter flutter
RUN cd flutter/app && flutter pub get && flutter build web --release --no-wasm-dry-run --no-web-resources-cdn

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
COPY --from=web /src/flutter/app/build/web /app/web
COPY docker/entrypoint.sh /app/entrypoint.sh
ENV TL_DATA=/data TL_WEB=/app/web TL_PORT=2778
VOLUME /data
EXPOSE 2778
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD ["/app/twimshelf-server", "--health"]
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
