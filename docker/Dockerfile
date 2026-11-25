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
# On-device AI tagging runs on the GPU the container is given (docker/README.md, GPU), one image
# for all of them, amd64 and arm64: AMD and Intel through /dev/dri (Vulkan, Mesa's drivers), NVIDIA
# through the NVIDIA Container Toolkit (CUDA). Without a GPU, on-device AI is off (never the
# processor); services still tag.

ARG RUST_VERSION
ARG NODE_VERSION
# llama.cpp's CUDA backend is built with this CUDA (major.minor), whose runtime and cuBLAS go into
# the image
ARG CUDA_VERSION=12.9

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

# ---- llama.cpp (flutter/tl_llama): Vulkan and CUDA, the core picks the device ----
# Ubuntu 24.04 with only the parts of CUDA the build needs (its compiler, runtime and cuBLAS) from
# NVIDIA's repository, for amd64 and arm64 alike: about a fifth of NVIDIA's development image to
# download. The driver's library is linked through its stub; the real one comes from the host
# through the NVIDIA Container Toolkit. The libraries find each other where they lie ($ORIGIN): the
# core opens libtl_llama.so in /app/llama. CUDA's runtime and cuBLAS go along, so the host needs
# only the driver.
FROM ubuntu:24.04 AS llama
ARG CUDA_VERSION
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && \
    repo="$(case "$TARGETARCH" in arm64) echo sbsa;; *) echo x86_64;; esac)" && \
    curl -fsSL -o /tmp/keyring.deb "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/$repo/cuda-keyring_1.1-1_all.deb" && \
    dpkg -i /tmp/keyring.deb && rm /tmp/keyring.deb && apt-get update && \
    v="$(echo "$CUDA_VERSION" | tr . -)" && \
    apt-get install -y --no-install-recommends cmake ninja-build g++ git glslc libvulkan-dev \
      "cuda-nvcc-$v" "cuda-cudart-dev-$v" "libcublas-dev-$v" && \
    rm -rf /var/lib/apt/lists/* && ln -sfn "/usr/local/cuda-$CUDA_VERSION" /usr/local/cuda
ENV PATH=/usr/local/cuda/bin:$PATH CUDACXX=/usr/local/cuda/bin/nvcc
WORKDIR /src
COPY flutter/tl_llama/src flutter/tl_llama/src
RUN --mount=type=cache,id=llama-gpu,target=/src/llama-build \
    cmake -S flutter/tl_llama/src -B /src/llama-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH='$ORIGIN' \
      -DTL_LLAMA_VULKAN=ON -DTL_LLAMA_VULKAN_HEADERS=ON -DTL_LLAMA_CUDA=ON && \
    cmake --build /src/llama-build --target tl_llama && \
    mkdir -p /llama && \
    find /src/llama-build -maxdepth 4 \( -type f -o -type l \) \
      \( -name 'libtl_llama.so*' -o -name 'libllama.so*' -o -name 'libmtmd.so*' -o -name 'libllama-common.so*' -o -name 'libggml*.so*' \) \
      -exec cp -P {} /llama/ \; && \
    cp -P /usr/local/cuda/lib64/libcudart.so.12* /usr/local/cuda/lib64/libcublas.so.12* /usr/local/cuda/lib64/libcublasLt.so.12* /llama/ && \
    test -e /llama/libggml-vulkan.so && test -e /llama/libggml-cuda.so

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

# ---- what runs: Ubuntu 24.04 (the C library llama.cpp was built against above) ----
FROM ubuntu:24.04
ARG VERSION=dev
LABEL org.opencontainers.image.title="TwimShelf" \
      org.opencontainers.image.description="TwimShelf Linux server: the library and the web app" \
      org.opencontainers.image.source="https://github.com/XGWYTWGDYU/TwimShelf" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"
# Vulkan: the loader and Mesa's drivers (AMD's RADV, Intel's ANV). Mesa's software renderer goes:
# it is the processor, which models never run on.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tini libgomp1 libvulkan1 mesa-vulkan-drivers && \
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
