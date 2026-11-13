#!/usr/bin/env bash
# One step from a fresh checkout to installable packages, on macOS and Linux.
#
#   ./build.sh                 everything this computer can build
#   ./build.sh flutter-android native-macos …
#   ./build.sh docker          the Linux server with the web app, as a Docker image
#   ./build.sh --list          the targets and where each can be built
#   ./build.sh --check         only check the tools; install nothing, build nothing
#   ./build.sh --configure     only apply config.yaml (names, ids, icons, share extension)
#
# Each build applies config.yaml first.
#
# Each missing tool is named with what installing it takes; nothing is installed without a yes
# (or --yes). Where things go is build.dir in config.yaml: every cache (Rust, Xcode, Flutter,
# Gradle, Dart packages, downloaded SDKs) in <dir>/cache, the packages in <dir>/apps. Optional:
#   FLUTTER_ROOT    an existing Flutter SDK                  (default: flutter on PATH, else one in <dir>/cache/sdk)
#   ANDROID_HOME    an existing Android SDK                  (default: <dir>/cache/sdk/android)
#   TL_UPDATE_REPO  owner/name: makes a GitHub build (检查更新); leave empty for local builds
#   TL_VERSION      the version in the packages' file names (default: version in config.yaml)
# Windows builds use build.ps1 on Windows.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS=$(uname -s)
CACHE="$(python3 "$ROOT/scripts/apply.py" where cache)"
DIST="$(python3 "$ROOT/scripts/apply.py" where apps)"
SDK="$CACHE/sdk"
YES=0; CHECK=0; TARGETS=()

# pinned versions: a build made today and one made in a year use the same tools
# (Flutter in .fvmrc, Rust in rust-toolchain.toml; rustup installs that one on first use)
FLUTTER_VERSION=$(sed -nE 's/.*"flutter": *"([^"]+)".*/\1/p' "$ROOT/.fvmrc")
RUST_TOOLCHAIN=$(sed -nE 's/^channel *= *"([^"]+)".*/\1/p' "$ROOT/rust-toolchain.toml")
ANDROID_PLATFORM=android-36
ANDROID_BUILD_TOOLS=36.0.0
ANDROID_CMAKE=3.31.6
APPIMAGETOOL_URL=https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage

all_targets() {
  case "$OS" in
    Darwin) echo native-macos native-ios flutter-macos flutter-ios flutter-android ;;
    Linux) echo flutter-linux flutter-android ;;
  esac
}

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ask() {   # ask "question" → 0 for yes
  [[ $YES == 1 ]] && return 0
  [[ $CHECK == 1 ]] && return 1
  read -r -p "$1 [y/N] " a; [[ $a == y || $a == Y ]]
}
have() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {   # pkg_install <what it is> <brew name> <apt name> <dnf name> <pacman name>
  local what=$1
  case "$OS" in
    Darwin) have brew || fail "Homebrew is needed to install $what: https://brew.sh"
            ask "Install $what with Homebrew (brew install $2)?" && brew install "$2" ;;
    Linux)
      if have apt-get; then ask "Install $what (sudo apt-get install $3)?" && sudo apt-get install -y $3
      elif have dnf; then ask "Install $what (sudo dnf install $4)?" && sudo dnf install -y $4
      elif have pacman; then ask "Install $what (sudo pacman -S $5)?" && sudo pacman -S --needed --noconfirm $5
      else fail "Install $what with your package manager, then run this again"; fi ;;
  esac
}

need_tool() {   # need_tool <command> <what> <brew> <apt> <dnf> <pacman>
  have "$1" && return 0
  say "Missing: $2"
  pkg_install "$2" "$3" "$4" "$5" "$6" || true
  have "$1" || { [[ $CHECK == 1 ]] && MISSING+=("$2") && return 0; fail "$2 is required"; }
}

need_rust() {
  export PATH="$HOME/.cargo/bin:$PATH"
  if ! have rustup; then
    say "Missing: Rust (rustup, about 300 MB)"
    if ask "Install Rust from rustup.rs into ~/.cargo?"; then
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "$RUST_TOOLCHAIN" --profile minimal
    else [[ $CHECK == 1 ]] && MISSING+=(Rust) && return 0; fail "Rust is required"; fi
  fi
}

need_flutter() {
  if [[ -n "${FLUTTER_ROOT:-}" && -x "$FLUTTER_ROOT/bin/flutter" ]]; then FLUTTER="$FLUTTER_ROOT/bin/flutter"
  elif have flutter; then FLUTTER=$(command -v flutter)
  elif [[ -x "$SDK/flutter/bin/flutter" ]]; then FLUTTER="$SDK/flutter/bin/flutter"
  else
    say "Missing: Flutter $FLUTTER_VERSION (about 1.5 GB with its caches)"
    if ask "Download Flutter $FLUTTER_VERSION into $SDK/flutter?"; then
      need_tool git Git git git git git
      git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$SDK/flutter"
      FLUTTER="$SDK/flutter/bin/flutter"
    else [[ $CHECK == 1 ]] && MISSING+=(Flutter) && return 0; fail "Flutter is required"; fi
  fi
  local have_version; have_version=$(cat "$(dirname "$FLUTTER")/../version" 2>/dev/null || true)
  [[ -z "$have_version" || "$have_version" == "$FLUTTER_VERSION" ]] ||
    printf '\033[33mFlutter %s is not the pinned %s (.fvmrc): the build may differ from the release builds\033[0m\n' "$have_version" "$FLUTTER_VERSION" >&2
  export PUB_CACHE="$CACHE/pub" GRADLE_USER_HOME="$CACHE/gradle"
  "$FLUTTER" config --no-analytics >/dev/null 2>&1 || true
}

need_android() {
  export ANDROID_HOME="${ANDROID_HOME:-$SDK/android}"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  have java || [[ -n "${JAVA_HOME:-}" ]] || need_tool java "Java 17+ (for Gradle)" openjdk@17 openjdk-17-jdk-headless java-17-openjdk-devel jdk17-openjdk
  local sdkm="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  if [[ ! -x "$sdkm" ]]; then
    say "Missing: Android SDK command-line tools"
    if ask "Download the Android command-line tools into $ANDROID_HOME (about 150 MB, more for the SDK parts)?"; then
      local zip="$SDK/cmdline-tools.zip" os=linux
      [[ $OS == Darwin ]] && os=mac
      mkdir -p "$ANDROID_HOME/cmdline-tools"
      curl -fL -o "$zip" "https://dl.google.com/android/repository/commandlinetools-${os}-13114758_latest.zip"
      unzip -q -o "$zip" -d "$ANDROID_HOME/cmdline-tools" && rm -rf "$ANDROID_HOME/cmdline-tools/latest" && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    else [[ $CHECK == 1 ]] && MISSING+=("Android SDK") && return 0; fail "The Android SDK is required"; fi
  fi
  # the NDK Flutter asks for, and CMake for llama.cpp
  local ndk; ndk=$(sed -nE 's/.*ndkVersion[^=]*= "([^"]+)".*/\1/p' "$(dirname "$FLUTTER")/../packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt" | head -1)
  local parts=("platform-tools" "platforms;$ANDROID_PLATFORM" "build-tools;$ANDROID_BUILD_TOOLS" "ndk;$ndk" "cmake;$ANDROID_CMAKE")
  local missing=()
  for p in "${parts[@]}"; do [[ -d "$ANDROID_HOME/${p//;//}" ]] || missing+=("$p"); done
  if (( ${#missing[@]} )); then
    say "Missing Android SDK parts: ${missing[*]} (the NDK is about 1 GB)"
    if ask "Install them with sdkmanager?"; then
      yes | "$sdkm" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
      "$sdkm" --sdk_root="$ANDROID_HOME" "${missing[@]}"
    else [[ $CHECK == 1 ]] && MISSING+=("Android SDK parts") && return 0; fail "The Android SDK parts are required"; fi
  fi
  export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ndk"
  have cargo-ndk || { ask "Install cargo-ndk (cargo install cargo-ndk)?" && cargo install cargo-ndk; } || true
}

need_xcode() {
  have xcodebuild || fail "Install Xcode from the App Store, open it once, then run this again"
  xcode-select -p >/dev/null 2>&1 || fail "Run: sudo xcode-select -s /Applications/Xcode.app"
}

# the native Xcode project is made from project.yml (scripts/apply.py runs it; not in git)
need_xcodegen() { [[ $OS == Darwin ]] && need_tool xcodegen "XcodeGen (makes the Xcode project from project.yml)" xcodegen - - - || true; }

# A release-signed APK on this computer: config.local.yaml names the keystore (android.keystore,
# android.key_alias) and the keychain item holding its password (android.keychain_service).
# key.properties is written for this build only. CI writes its own from the repository's secrets.
ANDROID_KEY_WRITTEN=0
android_key() {
  local props="$ROOT/flutter/app/android/key.properties" store alias service pass
  [[ -f "$props" ]] && return 0
  store=$(python3 "$ROOT/scripts/apply.py" get android.keystore 2>/dev/null) || return 0
  alias=$(python3 "$ROOT/scripts/apply.py" get android.key_alias)
  service=$(python3 "$ROOT/scripts/apply.py" get android.keychain_service)
  store="${store/#\~/$HOME}"
  [[ -f "$store" ]] || fail "The Android keystore $store (config.local.yaml) does not exist"
  pass=$(security find-generic-password -s "$service" -w 2>/dev/null) || fail "No keychain item \"$service\" with the keystore's password (config.local.yaml)"
  printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' "$store" "$pass" "$alias" "$pass" > "$props"
  ANDROID_KEY_WRITTEN=1
  trap '[[ $ANDROID_KEY_WRITTEN == 1 ]] && rm -f "$ROOT/flutter/app/android/key.properties"' EXIT
}

need_flutter_apple() {
  need_tool cmake "CMake (the HEIC decoder in the Rust core)" cmake - - -
  need_tool pod "CocoaPods" cocoapods - - -
  # CocoaPods fails on non-ASCII text without a UTF-8 locale
  export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
}

need_linux_desktop() {
  local t
  for t in clang cmake ninja pkg-config; do
    need_tool $t "$t" - "clang cmake ninja-build pkg-config" "clang cmake ninja-build pkgconf-pkg-config" "clang cmake ninja pkgconf"
  done
  pkg-config --exists gtk+-3.0 || pkg_install "GTK 3 headers" - libgtk-3-dev gtk3-devel gtk3 || true
  pkg-config --exists mpv || pkg_install "libmpv (video)" - libmpv-dev mpv-libs-devel mpv || true
  pkg-config --exists libsecret-1 || pkg_install "libsecret (where the app keeps its keys)" - libsecret-1-dev libsecret-devel libsecret || true
  pkg-config --exists alsa || pkg_install "ALSA headers (the volume)" - libasound2-dev alsa-lib-devel alsa-lib || true
  { pkg-config --exists vulkan && have glslc; } || pkg_install "Vulkan headers and shader compiler (GPU AI)" - "libvulkan-dev glslc" "vulkan-loader-devel glslc" "vulkan-headers vulkan-icd-loader shaderc" || true
  pkg-config --exists SPIRV-Headers || pkg_install "SPIR-V headers (GPU AI)" - spirv-headers spirv-headers-devel spirv-headers || true
  have file || need_tool file file - file file file
}

version() {
  if [[ -n "${TL_VERSION:-}" ]]; then echo "$TL_VERSION"; else python3 "$ROOT/scripts/apply.py" get version; fi
}

# Follow the workspace's configured Derived Data location, just like Xcode's UI.
# Xcode may append a project-specific directory to that location; ask for the actual
# product directory instead of maintaining a second hard-coded cache layout.
native_products() {
  local scheme=$1 destination=$2
  xcodebuild -project "$ROOT/TwimShelf.xcodeproj" -scheme "$scheme" -configuration Release \
    -destination "$destination" -showBuildSettings -json |
    python3 -c 'import json,sys; rows=json.load(sys.stdin); print(next(r["buildSettings"]["BUILT_PRODUCTS_DIR"] for r in rows if r["target"] == sys.argv[1]))' "$scheme"
}

flutter_defines() {
  local d=("--dart-define=TL_SHARE=$(python3 "$ROOT/scripts/apply.py" get flutter.share_extension)")
  [[ -n "${TL_UPDATE_REPO:-}" ]] && d+=("--dart-define=TL_UPDATE_REPO=$TL_UPDATE_REPO")
  echo "${d[@]:-}"
}

core_for() { FLUTTER="$FLUTTER" "$ROOT/scripts/flutter/build_core.sh" "$1"; }

build_target() {
  local t=$1 v; v=$(version)
  mkdir -p "$DIST"
  case "$t" in
    native-macos)
      need_xcode; need_rust
      xcodebuild -project "$ROOT/TwimShelf.xcodeproj" -scheme TwimShelf-macOS -configuration Release \
        -destination 'platform=macOS,arch=arm64' ${TL_UPDATE_REPO:+TL_UPDATE_REPO=$TL_UPDATE_REPO} build
      local products; products=$(native_products TwimShelf-macOS 'platform=macOS,arch=arm64')
      "$ROOT/scripts/package_dmg.sh" "$products/TwimShelf.app" "$DIST/TwimShelf-$v-macOS-arm64.dmg" ;;
    native-ios)
      need_xcode; need_rust
      xcodebuild -project "$ROOT/TwimShelf.xcodeproj" -scheme TwimShelf-iOS -configuration Release -destination generic/platform=iOS \
        ${TL_UPDATE_REPO:+TL_UPDATE_REPO=$TL_UPDATE_REPO} CODE_SIGNING_ALLOWED=NO build
      local products; products=$(native_products TwimShelf-iOS 'generic/platform=iOS')
      "$ROOT/scripts/package_ipa.sh" "$products/TwimShelf.app" "$DIST/TwimShelf-$v-iOS-unsigned.ipa" ;;
    flutter-macos|flutter-ios)
      need_xcode; need_rust; need_flutter; need_flutter_apple
      core_for "${t#flutter-}"
      # without a fresh pod install, the pods' frameworks come out without their Info.plist
      # (signing or installing then refuses them)
      # and CocoaPods reads the engine's files: a fresh Flutter SDK has to fetch them first
      (cd "$ROOT/flutter/app" && "$FLUTTER" precache --"${t#flutter-}" && "$FLUTTER" pub get && cd "${t#flutter-}" && pod install)
      (cd "$ROOT/flutter/app" && "$FLUTTER" build "${t#flutter-}" --release $( [[ $t == flutter-ios ]] && echo --no-codesign ) $(flutter_defines))
      if [[ $t == flutter-macos ]]; then
        "$ROOT/scripts/package_dmg.sh" "$(ls -d "$ROOT"/flutter/app/build/macos/Build/Products/Release/*.app | head -1)" "$DIST/TwimShelf-Flutter-$v-macOS.dmg"
      else
        "$ROOT/scripts/package_ipa.sh" "$ROOT/flutter/app/build/ios/iphoneos/Runner.app" "$DIST/TwimShelf-Flutter-$v-iOS-unsigned.ipa"
      fi ;;
    flutter-android)
      need_rust; need_flutter; need_android
      [[ $OS == Darwin ]] && android_key
      PATH="$ANDROID_HOME/cmake/$ANDROID_CMAKE/bin:$PATH" core_for android
      (cd "$ROOT/flutter/app" && "$FLUTTER" pub get && "$FLUTTER" build apk --release --split-per-abi $(flutter_defines))
      for f in "$ROOT"/flutter/app/build/app/outputs/flutter-apk/app-*-release.apk; do
        abi=$(basename "$f" | sed -E 's/app-(.*)-release.apk/\1/')
        cp "$f" "$DIST/TwimShelf-Flutter-$v-android-$abi.apk"
      done ;;
    flutter-linux)
      [[ $OS == Linux ]] || fail "flutter-linux builds on Linux"
      need_rust; need_flutter; need_linux_desktop
      core_for linux
      (cd "$ROOT/flutter/app" && "$FLUTTER" pub get && "$FLUTTER" build linux --release $(flutter_defines))
      local arch; arch=$(uname -m); [[ $arch == aarch64 ]] && arch=arm64 || arch=x64
      "$ROOT/scripts/flutter/package_appimage.sh" "$ROOT/flutter/app/build/linux/$arch/release/bundle" "$DIST" "$v" ;;
    docker)
      # the Linux server and the web app; everything is compiled inside the image, so this
      # computer needs only Docker (its own build cache stays in Docker's storage)
      have docker || fail "Docker is needed: https://docs.docker.com/get-docker/ (or OrbStack, Colima)"
      docker build -f "$ROOT/docker/Dockerfile" --build-arg VERSION="$v" --build-arg RUST_VERSION="$RUST_TOOLCHAIN" --build-arg FLUTTER_VERSION="$FLUTTER_VERSION" -t "twimshelf:$v" -t twimshelf:latest "$ROOT"
      local arch; arch=$(docker image inspect --format '{{.Architecture}}' "twimshelf:$v")
      docker save "twimshelf:$v" | gzip > "$DIST/TwimShelf-$v-docker-linux-$arch.tar.gz" ;;
    flutter-windows) fail "flutter-windows builds on Windows: build.ps1" ;;
    *) fail "Unknown target: $t (see --list)" ;;
  esac
  say "Built $t"
}

while (( $# )); do
  case "$1" in
    --yes|-y) YES=1; export TL_YES=1 ;;
    --check) CHECK=1 ;;
    --configure) need_xcodegen; python3 "$ROOT/scripts/apply.py"; exit ;;
    --list) cat <<EOF
native-macos     the native Mac app (.dmg)                 macOS with Xcode
native-ios       the native iPhone/iPad app (unsigned .ipa) macOS with Xcode
flutter-macos    the Flutter Mac app (.dmg)                macOS with Xcode
flutter-ios      the Flutter iPhone/iPad app (.ipa)        macOS with Xcode
flutter-android  the Flutter Android app (.apk per ABI)    macOS or Linux (Windows: build.ps1)
flutter-linux    the Flutter Linux app (.AppImage)         Linux
flutter-windows  the Flutter Windows app (setup .exe)      Windows: build.ps1
docker           the Linux server + web app (image, .tar.gz) any computer with Docker (not built by default)
This computer builds by default: $(all_targets)
EOF
      exit 0 ;;
    -*) fail "Unknown option $1" ;;
    *) TARGETS+=("$1") ;;
  esac
  shift
done
(( ${#TARGETS[@]} )) || read -r -a TARGETS <<< "$(all_targets)"
MISSING=()
mkdir -p "$CACHE" "$DIST"

if [[ $CHECK == 1 ]]; then
  for t in "${TARGETS[@]}"; do
    case "$t" in
      native-*) need_xcode; need_xcodegen; need_rust ;;
      flutter-macos|flutter-ios) need_xcode; need_rust; need_flutter; need_flutter_apple ;;
      flutter-android) need_rust; need_flutter; need_android ;;
      flutter-linux) need_rust; need_flutter; need_linux_desktop ;;
      docker) have docker || MISSING+=(Docker) ;;
    esac
  done
  (( ${#MISSING[@]} )) && { say "Missing: ${MISSING[*]}"; exit 1; }
  say "Everything needed for ${TARGETS[*]} is here"; exit 0
fi

need_xcodegen
python3 "$ROOT/scripts/apply.py"
for t in "${TARGETS[@]}"; do build_target "$t"; done
say "Packages: $DIST"
ls -1 "$DIST"
