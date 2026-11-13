#!/bin/zsh
# Builds tl-core for the current Xcode platform into $BUILT_PRODUCTS_DIR.
# Needs rustup (./build.sh --check installs it); the pinned Rust (rust-toolchain.toml) and the
# target are added on first use.
set -e
if [ ! -x "$HOME/.cargo/bin/rustup" ]; then
  echo "error: Rust is missing: run ./build.sh --check"
  exit 1
fi
[ -f ~/.cargo/env ] && source ~/.cargo/env
cd "$SRCROOT/core"
case "$PLATFORM_NAME" in
  iphoneos) T=aarch64-apple-ios; S=iphoneos ;;
  iphonesimulator) T=aarch64-apple-ios-sim; S=iphonesimulator ;;
  *) T=aarch64-apple-darwin; S=macosx ;;
esac
# Always optimize the core: crypto/hashing generics are instantiated in our crate, and an
# unoptimized core syncs ~14x slower (8 vs 110 MB/s measured). Debug info stays in release builds.
P=release
FLAG=--release
rustup target list --installed | grep -qx "$T" || rustup target add "$T"
# build.dir of config.yaml (Xcode passes TL_CACHE_DIR from BuildLocation.xcconfig)
CACHE="${TL_CACHE_DIR:-$(python3 "$SRCROOT/scripts/apply.py" where cache)}"
env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/usr/bin:/bin" SDKROOT="$(xcrun --sdk $S --show-sdk-path)" DEVELOPER_DIR="$DEVELOPER_DIR" CARGO_TARGET_DIR="$CACHE/cargo" cargo build $FLAG --target $T
cp "$CACHE/cargo/$T/$P/libtl_core.a" "$BUILT_PRODUCTS_DIR/libtl_core.a"
