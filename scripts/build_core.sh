#!/bin/zsh
# Builds tl-core for the current Xcode platform into $BUILT_PRODUCTS_DIR.
# A fresh Mac needs nothing else: Rust (per user, no administrator rights) and the target are
# installed on the first build.
set -e
if [ ! -x "$HOME/.cargo/bin/rustup" ]; then
  echo "note: installing Rust into ~/.cargo (first build only)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
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
