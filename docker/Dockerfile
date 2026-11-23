# TwimShelf Linux server: the Rust core and the web app on one port.
#
#   ./build.sh docker            (passes the pinned Rust and Node versions, see below)
#   docker run -d -p 2778:2778 -v /path/to/data:/data twimshelf
#
# /app holds the program (server + web app), /data everything it keeps (see docker/README.md).
# The version is config.yaml's, as for every other build (./build.sh docker builds and saves it).
# The tools are the repository's pinned ones: RUST_VERSION from rust-toolchain.toml, NODE_VERSION
# from .node-version (docker build --build-arg RUST_VERSION=… --build-arg NODE_VERSION=… by hand).
#
# On-device AI tagging runs on the GPU when the container is given one (docker/README.md, GPU):
#   GPU=vulkan (the default)  AMD and Intel through /dev/dri (Mesa's drivers), amd64 and arm64
#   GPU=cuda                  NVIDIA through the NVIDIA Container Toolkit, amd64 only
#                             (./build.sh docker-cuda passes the CUDA runtime image as RUNTIME too)
# Without one it runs on the processor.

ARG RUST_VERSION
ARG NODE_VERSION
ARG GPU=vulkan
# the CUDA image's runtime: the same CUDA as its build stage (llama-cuda below)
ARG CUDA_VERSION=12.9.1
ARG RUNTIME=debian:bookworm-slim

# ---- the server: the core with HEIC/AVIF, built from pinned sources ----
FROM rust:${RUST_VERSION}-bookworm AS server
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build nasm meson pkg-config g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY config.yaml Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY core core
COPY server server
# owner/name of a GitHub build: the web page then tells of newer releases (empty: never looks)
ARG TL_UPDATE_REPO=""
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    export TL_VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' config.yaml)" TL_UPDATE_REPO="$TL_UPDATE_REPO" && \
    cargo build -p tl-server --release --locked && cp target/release/twimshelf-server /twimshelf-server

# ---- llama.cpp (flutter/tl_llama), the backend the GPU argument names ----
# The libraries find each other where they lie ($ORIGIN): libtl_llama.so is opened by path (llama.rs).
# Vulkan: Debian's shader compiler, headers and SPIR-V headers are enough for llama.cpp's backend.
FROM rust:${RUST_VERSION}-bookworm AS llama-vulkan
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build g++ glslc libvulkan-dev spirv-headers && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY flutter/tl_llama/src flutter/tl_llama/src
RUN --mount=type=cache,id=llama-vulkan,target=/src/llama-build \
    cmake -S flutter/tl_llama/src -B /src/llama-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH='$ORIGIN' -DTL_LLAMA_VULKAN=ON -DTL_LLAMA_VULKAN_HEADERS=ON && \
    cmake --build /src/llama-build --target tl_llama && \
    mkdir -p /llama && \
    find /src/llama-build -maxdepth 4 \( -type f -o -type l \) \
      \( -name 'libtl_llama.so*' -o -name 'libllama.so*' -o -name 'libmtmd.so*' -o -name 'libggml*.so*' \) \
      -exec cp -P {} /llama/ \; && \
    test -e /llama/libggml-vulkan.so

# CUDA: NVIDIA's development image (the driver's library is linked through its stub; the real one
# comes from the host through the NVIDIA Container Toolkit).
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS llama-cuda
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build g++ ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY flutter/tl_llama/src flutter/tl_llama/src
RUN --mount=type=cache,id=llama-cuda,target=/src/llama-build \
    cmake -S flutter/tl_llama/src -B /src/llama-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH='$ORIGIN' -DTL_LLAMA_VULKAN=OFF -DTL_LLAMA_CUDA=ON && \
    cmake --build /src/llama-build --target tl_llama && \
    mkdir -p /llama && \
    find /src/llama-build -maxdepth 4 \( -type f -o -type l \) \
      \( -name 'libtl_llama.so*' -o -name 'libllama.so*' -o -name 'libmtmd.so*' -o -name 'libggml*.so*' \) \
      -exec cp -P {} /llama/ \; && \
    test -e /llama/libggml-cuda.so

FROM llama-${GPU} AS llama

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

# ---- what runs: Debian, or NVIDIA's CUDA runtime for GPU=cuda ----
FROM ${RUNTIME}
ARG VERSION=dev
ARG GPU=vulkan
LABEL org.opencontainers.image.title="TwimShelf" \
      org.opencontainers.image.description="TwimShelf Linux server: the library and the web app" \
      org.opencontainers.image.source="https://github.com/XGWYTWGDYU/TwimShelf" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"
# Vulkan: the loader and Mesa's drivers (AMD's RADV, Intel's ANV). Mesa's software renderer goes:
# without a GPU the model runs on llama.cpp's own CPU backend, which is far faster than it.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tini libgomp1 \
      $([ "$GPU" = vulkan ] && echo libvulkan1 mesa-vulkan-drivers) && \
    rm -rf /var/lib/apt/lists/* /usr/share/vulkan/icd.d/lvp_icd.*.json
COPY --from=server /twimshelf-server /app/twimshelf-server
COPY --from=llama /llama /app/llama
# `docker exec -it <container> twimshelf passwd`
RUN ln -s /app/twimshelf-server /usr/local/bin/twimshelf
COPY --from=web /src/web/app/dist /app/web
COPY docker/entrypoint.sh /app/entrypoint.sh
ENV TL_DATA=/data TL_WEB=/app/web TL_PORT=2778
VOLUME /data
EXPOSE 2778
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD ["/app/twimshelf-server", "--health"]
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
