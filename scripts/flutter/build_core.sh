#!/usr/bin/env bash
# Builds the Rust core for the Flutter app; all caches and output go to build.dir of config.yaml.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
usage() { echo 'Usage: build_core.sh android|windows|linux|macos|ios [--debug]' >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage
platform=$1
profile=release
flags=(--release)
if [[ $# == 2 ]]; then
  [[ $2 == --debug ]] || usage
  profile=debug
  flags=(--profile dev)
fi
case "$platform" in android|windows|linux|macos|ios) ;; *) usage ;; esac
if [[ $profile == release ]]; then
  export CARGO_PROFILE_RELEASE_STRIP=symbols
  export CARGO_PROFILE_RELEASE_DEBUG=0
  export CARGO_PROFILE_RELEASE_LTO=true
  export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
  # FFI envelopes catch Rust panics; an abort would terminate the host app.
  export CARGO_PROFILE_RELEASE_PANIC=unwind
fi
# where things go comes from the caller (build.sh at the root, or your shell): nothing machine-specific here
# build.dir of config.yaml: every cache under <dir>/cache
CACHE="$(python3 "$ROOT/scripts/apply.py" where cache)"
export PATH="$CACHE/sdk/bin:$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="$CACHE/cargo"
export XWIN_CACHE_DIR="$CACHE/xwin"
export ANDROID_HOME="${ANDROID_HOME:-$CACHE/sdk/android}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
if [[ -z "${JAVA_HOME:-}" && -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' ]]; then
  export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
fi
HEADER="$ROOT/native/Shared/tl_core.h"
DEST="$ROOT/flutter/tl_core"
expected=$(awk '/^[a-zA-Z_].*tl_[a-zA-Z0-9_]+\(/ { line=$0; sub(/\(.*/, "", line); sub(/.*[ *]/, "", line); print line }' "$HEADER" | sort -u)
expected_count=$(printf '%s\n' "$expected" | wc -l | tr -d ' ')
fail() { echo "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "Missing tool: $1"; }
need cargo
need rustup
need cmake
mkdir -p "$CARGO_TARGET_DIR"
cd "$ROOT/core"
targets() { rustup target add "$@"; }
shared() { cargo rustc --locked --lib "${flags[@]}" --features heif --target "$1" --crate-type cdylib; }
static() { cargo build --locked --lib "${flags[@]}" --features heif --target "$1"; }
# Compare the actual symbol names as well as the count. Static archives may contain
# duplicate undefined references; only unique, externally defined C functions count.
report() {
  local file=$1 kind=$2 arch=${3:-} symbols count
  case "$kind" in
    apple)
      symbols=$(xcrun nm --no-llvm-bc --quiet ${arch:+-arch "$arch"} -gU "$file" | awk '{print $NF}' | sed -nE 's/^_(tl_[a-zA-Z0-9_]+)$/\1/p' | sort -u) ;;
    import)
      symbols=$("$NM" --defined-only --extern-only "$file" | awk '{print $NF}' | sed -nE 's/^(tl_[a-zA-Z0-9_]+)$/\1/p' | sort -u) ;;
    windows)
      symbols=$("$OBJDUMP" -p "$file" | awk '{print $NF}' | sed -nE 's/^(tl_[a-zA-Z0-9_]+)$/\1/p' | sort -u) ;;
    *)
      symbols=$("$NM" --dynamic --defined-only "$file" | awk '{print $NF}' | sed -nE 's/^(tl_[a-zA-Z0-9_]+)$/\1/p' | sort -u) ;;
  esac
  count=$(printf '%s\n' "$symbols" | awk 'NF {n++} END {print n+0}')
  printf '%s%s: %s tl_ exports (header: %s)\n' "$file" "${arch:+ [$arch]}" "$count" "$expected_count"
  [[ "$symbols" == "$expected" ]] || fail "Exported functions differ from $HEADER"
}
case "$platform" in
  android)
    need cargo-ndk
    # Flutter declares its required NDK version in its Gradle plugin source.
    flutter_bin=$(command -v "${FLUTTER:-flutter}") || fail 'Flutter not found (set FLUTTER or FLUTTER_ROOT)'
    flutter_gradle="$(cd "$(dirname "$(readlink -f "$flutter_bin" 2>/dev/null || echo "$flutter_bin")")/.." && pwd)/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt"
    [[ -r "$flutter_gradle" ]] || fail "Flutter Gradle plugin missing: $flutter_gradle"
    ndk_version=$(sed -nE 's/.*ndkVersion[^=]*= "([^"]+)".*/\1/p' "$flutter_gradle" | head -1)
    [[ -n "$ndk_version" ]] || fail 'Cannot determine Flutter NDK version'
    export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ndk_version"
    [[ -d "$ANDROID_NDK_HOME" ]] || fail "Install NDK $ndk_version using sdkmanager --sdk_root=$ANDROID_HOME 'ndk;$ndk_version' (ask before downloads over 500 MB)"
    NM=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -name llvm-nm -type f -print -quit)
    [[ -x "$NM" ]] || fail 'NDK llvm-nm not found'
    targets aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
    cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 --platform 31 rustc --locked --lib "${flags[@]}" --features heif --crate-type cdylib
    for entry in arm64-v8a:aarch64-linux-android armeabi-v7a:armv7-linux-androideabi x86_64:x86_64-linux-android; do
      abi=${entry%%:*}; target=${entry#*:}
      mkdir -p "$DEST/android/src/main/jniLibs/$abi"
      cp "$CARGO_TARGET_DIR/$target/$profile/libtl_core.so" "$DEST/android/src/main/jniLibs/$abi/"
      report "$DEST/android/src/main/jniLibs/$abi/libtl_core.so" elf
    done ;;
  windows)
    need cargo-xwin
    targets x86_64-pc-windows-msvc
    rustup component add llvm-tools-preview
    # cargo-xwin reuses the Rust toolchain linker; Xcode supplies clang/LLVM.
    if [[ $(uname -s) == Darwin ]]; then
      export PATH="$(dirname "$(xcrun --find clang)"):$PATH"
    fi
    export XWIN_CROSS_COMPILER=clang
    export XWIN_ARCH=x86_64
    need clang
    OBJDUMP=$(command -v llvm-objdump || xcrun --find llvm-objdump)
    NM=$(command -v llvm-nm || xcrun --find llvm-nm)
    cargo xwin rustc --locked --lib "${flags[@]}" --features heif --target x86_64-pc-windows-msvc --crate-type cdylib
    mkdir -p "$DEST/windows/lib"
    for file in tl_core.dll tl_core.dll.lib; do
      cp "$CARGO_TARGET_DIR/x86_64-pc-windows-msvc/$profile/$file" "$DEST/windows/lib/$file"
    done
    report "$DEST/windows/lib/tl_core.dll" windows
    report "$DEST/windows/lib/tl_core.dll.lib" import ;;
  linux)
    [[ $(uname -s) == Linux ]] || fail 'The Linux core builds on Linux'
    case $(uname -m) in x86_64) target=x86_64-unknown-linux-gnu ;; aarch64|arm64) target=aarch64-unknown-linux-gnu ;; *) fail 'Unsupported Linux architecture' ;; esac
    NM=$(command -v llvm-nm || command -v nm)
    targets "$target"
    shared "$target"
    mkdir -p "$DEST/linux/lib"
    cp "$CARGO_TARGET_DIR/$target/$profile/libtl_core.so" "$DEST/linux/lib/"
    report "$DEST/linux/lib/libtl_core.so" elf ;;
  macos|ios)
    need xcrun; need xcodebuild
    # the oldest systems the Flutter app supports (its Podfiles / Xcode projects): without these
    # the library is built for this Mac's system and would not load on an older one
    export MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0
    targets aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
    for target in aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do static "$target"; done
    staging="$CARGO_TARGET_DIR/xcframework/$profile"
    mkdir -p "$staging/headers" "$DEST/apple"
    cp "$HEADER" "$staging/headers/tl_core.h"
    xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-darwin/$profile/libtl_core.a" "$CARGO_TARGET_DIR/x86_64-apple-darwin/$profile/libtl_core.a" -output "$staging/libtl_core.a"
    # Both entry points produce the complete XCFramework, retaining all Apple slices.
    rm -rf "$staging/TlCore.xcframework"
    xcodebuild -create-xcframework -library "$staging/libtl_core.a" -headers "$staging/headers" -library "$CARGO_TARGET_DIR/aarch64-apple-ios/$profile/libtl_core.a" -headers "$staging/headers" -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/$profile/libtl_core.a" -headers "$staging/headers" -output "$staging/TlCore.xcframework"
    rm -rf "$DEST/apple/TlCore.xcframework"
    cp -R "$staging/TlCore.xcframework" "$DEST/apple/"
    report "$DEST/apple/TlCore.xcframework/macos-arm64_x86_64/libtl_core.a" apple arm64
    report "$DEST/apple/TlCore.xcframework/macos-arm64_x86_64/libtl_core.a" apple x86_64
    report "$DEST/apple/TlCore.xcframework/ios-arm64/libtl_core.a" apple arm64
    report "$DEST/apple/TlCore.xcframework/ios-arm64-simulator/libtl_core.a" apple arm64 ;;
esac
