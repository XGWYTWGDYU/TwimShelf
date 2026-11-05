#!/bin/bash
# Run by the Flutter app's Xcode schemes before every build (Product ▸ Build is all it takes):
# Rust, the Flutter SDK, the Dart packages and the Rust core library are put in place first.
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
FLUTTER_VERSION=3.47.8
fail() {
  echo "FAILED: $*"
  osascript -e "display notification \"$* — see build/cache/logs/xcode-prepare.log\" with title \"TwimShelf build\"" >/dev/null 2>&1 || true
  exit 1
}
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# Xcode runs pre-actions without a locale; CocoaPods needs UTF-8
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

# Rust (per user, no administrator rights)
if ! command -v rustup >/dev/null; then
  echo "Installing Rust into ~/.cargo"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal || fail "Could not install Rust"
fi

# Flutter: the one this checkout was prepared with, one on PATH, or a pinned one in <build.dir>/cache/sdk
gen="$ROOT/flutter/app/$platform/Flutter/$( [[ $platform == ios ]] && echo Generated.xcconfig || echo ephemeral/Flutter-Generated.xcconfig )"
FLUTTER_ROOT=$(sed -nE 's/^FLUTTER_ROOT=(.*)/\1/p' "$gen" 2>/dev/null)
if [[ ! -x "${FLUTTER_ROOT:-/nonexistent}/bin/flutter" ]]; then
  if command -v flutter >/dev/null; then FLUTTER_ROOT="$(cd "$(dirname "$(readlink -f "$(command -v flutter)")")/.." && pwd)"
  else
    FLUTTER_ROOT="$CACHE/sdk/flutter"
    if [[ ! -x "$FLUTTER_ROOT/bin/flutter" ]]; then
      echo "Downloading Flutter $FLUTTER_VERSION into $FLUTTER_ROOT"
      git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_ROOT" || fail "Could not download Flutter"
    fi
  fi
fi
FLUTTER="$FLUTTER_ROOT/bin/flutter"
export PUB_CACHE="$CACHE/pub"

# config.yaml: the name, bundle id, icon and build location this build gets
python3 "$ROOT/scripts/apply.py" flutter || fail "Applying config.yaml failed"

# Dart packages (writes the Generated.xcconfig Xcode reads next)
(cd "$ROOT/flutter/app" && "$FLUTTER" pub get) || fail "flutter pub get failed"

# the Rust core, when it is missing or older than its sources
fw="$ROOT/flutter/tl_core/apple/TlCore.xcframework"
newest=$(find "$ROOT/core/src" "$ROOT/core/Cargo.toml" -newer "$fw" -print -quit 2>/dev/null)
if [[ ! -d "$fw" || -n "$newest" ]]; then
  FLUTTER="$FLUTTER" "$ROOT/scripts/flutter/build_core.sh" "$platform" || fail "Building the Rust core failed"
fi

# CocoaPods (the plugins that are not Swift packages yet)
if [[ -f "$ROOT/flutter/app/$platform/Podfile" ]]; then
  command -v pod >/dev/null || { command -v brew >/dev/null && brew install cocoapods; } || fail "CocoaPods is needed: brew install cocoapods"
  (cd "$ROOT/flutter/app/$platform" && pod install) || fail "pod install failed"
fi
echo "Prepared $platform"
