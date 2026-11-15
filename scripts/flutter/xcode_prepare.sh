#!/bin/bash
# Run by the Flutter app's Xcode schemes before every build: config.yaml, the Dart packages, the
# Rust core library and the pods are put in place first. It installs no tools: a missing one is
# named (./build.sh --check flutter-ios or flutter-macos lists them; with --yes it installs them).
# Xcode does not show a pre-action's output: it goes to <build.dir>/cache/logs/xcode-prepare.log, and a
# failure also shows as a notification.
#   xcode_prepare.sh ios|macos
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# build.dir of config.yaml: caches, logs and downloaded SDKs under <dir>/cache
CACHE="$(python3 "$ROOT/scripts/apply.py" where cache 2>/dev/null || echo "$ROOT/build/cache")"
mkdir -p "$CACHE/logs"
LOG="$CACHE/logs/xcode-prepare.log"
exec >"$LOG" 2>&1
platform=${1:-ios}
fail() {
  echo "FAILED: $*"
  osascript -e "display notification \"$* — see $LOG\" with title \"TwimShelf build\"" >/dev/null 2>&1 || true
  exit 1
}
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# Xcode runs pre-actions without a locale; CocoaPods needs UTF-8
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

command -v cargo >/dev/null || fail "Rust is missing: run ./build.sh --check"

# Flutter: the one this checkout was prepared with, one on PATH, or the one build.sh put in <build.dir>/cache/sdk
gen="$ROOT/flutter/app/$platform/Flutter/$( [[ $platform == ios ]] && echo Generated.xcconfig || echo ephemeral/Flutter-Generated.xcconfig )"
FLUTTER_ROOT=$(sed -nE 's/^FLUTTER_ROOT=(.*)/\1/p' "$gen" 2>/dev/null)
if [[ ! -x "${FLUTTER_ROOT:-/nonexistent}/bin/flutter" ]]; then
  if command -v flutter >/dev/null; then FLUTTER_ROOT="$(cd "$(dirname "$(readlink -f "$(command -v flutter)")")/.." && pwd)"
  else
    FLUTTER_ROOT="$CACHE/sdk/flutter"
    [[ -x "$FLUTTER_ROOT/bin/flutter" ]] || fail "Flutter is missing: run ./build.sh --check"
  fi
fi
FLUTTER="$FLUTTER_ROOT/bin/flutter"
export PUB_CACHE="$CACHE/pub"

# config.yaml: the name, bundle id, icon and build location this build gets
python3 "$ROOT/scripts/apply.py" flutter || fail "Applying config.yaml failed"

# Dart packages (writes the Generated.xcconfig Xcode reads next)
(cd "$ROOT/flutter/app" && "$FLUTTER" pub get) || fail "flutter pub get failed"

# the Rust core, when it is missing or older than what it is built from (its messages and the
# HEIC build are outside core/src; the header goes into the framework)
fw="$ROOT/flutter/tl_core/apple/$platform/TlCore.xcframework"
newest=$(find "$ROOT/core/src" "$ROOT/core/Cargo.toml" "$ROOT/core/build.rs" "$ROOT/core/messages.json" "$ROOT/core/heif" \
  "$ROOT/Cargo.lock" "$ROOT/rust-toolchain.toml" "$ROOT/native/Shared/tl_core.h" -newer "$fw" -print -quit 2>/dev/null)
if [[ ! -d "$fw" || -n "$newest" ]]; then
  FLUTTER="$FLUTTER" "$ROOT/scripts/flutter/build_core.sh" "$platform" || fail "Building the Rust core failed"
fi

# CocoaPods (the plugins that are not Swift packages yet)
if [[ -f "$ROOT/flutter/app/$platform/Podfile" ]]; then
  command -v pod >/dev/null || fail "CocoaPods is missing: run ./build.sh --check"
  # CocoaPods reads the engine's files: a fresh Flutter SDK has to fetch them first
  "$FLUTTER" precache --"$platform" || fail "Could not download the Flutter engine"
  # without INFOPLIST_FILE: Xcode exports the app target's to this pre-action, and with it set
  # CocoaPods leaves the pods' own Info.plist out of their frameworks (media_kit's then fail code
  # signing as "bundle format unrecognized"). The rest of the environment stays: CocoaPods may
  # need it (Ruby's gem paths on a CI runner).
  (cd "$ROOT/flutter/app/$platform" && env -u INFOPLIST_FILE pod install) || fail "pod install failed"
fi
echo "Prepared $platform"
