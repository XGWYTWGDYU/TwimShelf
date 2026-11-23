#!/usr/bin/env bash
# One step from a fresh checkout to installable packages, on macOS and Linux.
#
#   ./build.sh                 everything this computer can build
#   ./build.sh flutter-android native-macos …
#   ./build.sh docker          the Linux server with the web app, as a Docker image
#   ./build.sh docker-cuda     the same with NVIDIA (CUDA) on-device AI, amd64
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

all_targets() {
  case "$OS" in
    Darwin) echo native-macos native-ios flutter-ios flutter-android ;;
    Linux) echo electron-linux flutter-android ;;
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
  # rustup.rs puts Rust in ~/.cargo/bin; Homebrew's rustup is not linked into its bin (as scripts/build_core.sh)
  export PATH="$HOME/.cargo/bin:$PATH:/opt/homebrew/opt/rustup/bin:/usr/local/opt/rustup/bin"
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
  [[ -n "${FLUTTER:-}" ]] || return 0   # --check without Flutter: already listed as missing
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

# Node (React front end, Electron): the version in .node-version, from PATH or the build cache
need_node() {
  local want; want=$(tr -d ' \n' < "$ROOT/.node-version")
  if [[ -x "$SDK/node-$want/bin/node" ]]; then export PATH="$SDK/node-$want/bin:$PATH"; fi
  if have node && [[ $(node -v) == "v$want" ]]; then return 0; fi
  local os arch; os=$( [[ $OS == Darwin ]] && echo darwin || echo linux ); arch=$(uname -m)
  [[ $arch == x86_64 ]] && arch=x64; [[ $arch == aarch64 ]] && arch=arm64
  say "Missing: Node $want"
  if ask "Download Node $want (about 50 MB) into $SDK?"; then
    local tar="node-v$want-$os-$arch.tar.xz" tmp; tmp=$(mktemp -d)
    curl -fL --progress-bar "https://nodejs.org/dist/v$want/$tar" -o "$tmp/$tar"
    (cd "$tmp" && curl -fsSL "https://nodejs.org/dist/v$want/SHASUMS256.txt" | grep " $tar\$" | shasum -a 256 -c -)
    mkdir -p "$SDK" && tar -xJf "$tmp/$tar" -C "$SDK" && mv "$SDK/node-v$want-$os-$arch" "$SDK/node-$want" && rm -rf "$tmp"
    export PATH="$SDK/node-$want/bin:$PATH"
  fi
  have node || { [[ $CHECK == 1 ]] && MISSING+=("Node $want") && return 0; fail "Node $want is required"; }
}

# the React app (web/app/dist), what the server and the desktop app show
build_web() {
  need_node
  export npm_config_cache="$CACHE/npm" ELECTRON_CACHE="$CACHE/electron" electron_config_cache="$CACHE/electron"
  (cd "$ROOT/web" && npm ci --no-audit --no-fund && npm run check && npm run build)
}

# on-device GGUF inference (llama.cpp + tl_llama) for the Linux desktop app
build_llama_linux() {   # build_llama_linux <output directory>
  need_tool cmake CMake cmake cmake cmake cmake
  need_tool ninja Ninja ninja ninja-build ninja-build ninja
  local build="$CACHE/llama-linux" out=$1
  local extra=()
  [[ -n "${TL_LLAMA_SOURCE:-}" ]] && extra+=("-DTL_LLAMA_SOURCE=$TL_LLAMA_SOURCE")
  local vk=OFF; have glslc && vk=ON
  # The packaged libraries sit together, so resolve them relative to each other.
  cmake -S "$ROOT/flutter/tl_llama/src" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH='$ORIGIN' \
    -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$build/lib" -DTL_LLAMA_VULKAN=$vk -DTL_LLAMA_VULKAN_HEADERS=ON "${extra[@]}"
  cmake --build "$build" --target tl_llama
  rm -rf "$out" && mkdir -p "$out"
  find "$build" -maxdepth 4 -type f -name 'lib*.so*' \
    \( -name 'libtl_llama.so*' -o -name 'libllama.so*' -o -name 'libmtmd.so*' -o -name 'libggml*.so*' \) \
    -exec cp -P {} "$out/" \;
  find "$build" -maxdepth 4 -type l -name 'lib*.so*' \
    \( -name 'libtl_llama.so*' -o -name 'libllama.so*' -o -name 'libmtmd.so*' -o -name 'libggml*.so*' \) \
    -exec cp -P {} "$out/" \;
  [[ $vk == OFF || -e "$out/libggml-vulkan.so" ]] || fail "llama.cpp's Vulkan backend was not built (see $build)"
}

# the desktop app: React + the server binary in Electron
build_electron() {   # build_electron <linux|mac>
  need_rust; build_web
  # Electron's own binary (npm ci does not run its download step everywhere; cached in $CACHE/electron)
  (cd "$ROOT/web" && node node_modules/electron/install.js)
  cargo build --manifest-path "$ROOT/Cargo.toml" -p tl-server --release --locked --target-dir "$CACHE/cargo-target"
  local llama_dir=""
  if [[ "$1" == "linux" ]]; then
    llama_dir="$CACHE/llama-linux-out"
    build_llama_linux "$llama_dir"
  fi
  # name, id, version, build number and icon from config.yaml (product.json, icon.png)
  python3 "$ROOT/scripts/apply.py" desktop
  ELECTRON_OUT="$CACHE/electron-out"; local out=$ELECTRON_OUT; rm -rf "$out"
  (cd "$ROOT/web/electron" && TL_SERVER_BIN="$CACHE/cargo-target/release/twimshelf-server" TL_WEB_DIST="$ROOT/web/app/dist" \
    TL_LLAMA_DIR="$llama_dir" \
    TL_ELECTRON_OUT="$out" npx electron-builder --config builder.cjs --"$1" --publish never)
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
    flutter-ios)
      need_xcode; need_rust; need_flutter; need_flutter_apple
      core_for "${t#flutter-}"
      # without a fresh pod install, the pods' frameworks come out without their Info.plist
      # (signing or installing then refuses them)
      # and CocoaPods reads the engine's files: a fresh Flutter SDK has to fetch them first
      (cd "$ROOT/flutter/app" && "$FLUTTER" precache --"${t#flutter-}" && "$FLUTTER" pub get && cd "${t#flutter-}" && pod install)
      (cd "$ROOT/flutter/app" && "$FLUTTER" build "${t#flutter-}" --release $( [[ $t == flutter-ios ]] && echo --no-codesign ) $(flutter_defines))
      "$ROOT/scripts/package_ipa.sh" "$ROOT/flutter/app/build/ios/iphoneos/Runner.app" "$DIST/TwimShelf-Flutter-$v-iOS-unsigned.ipa" ;;
    flutter-android)
      need_rust; need_flutter; need_android
      [[ $OS == Darwin ]] && android_key
      PATH="$ANDROID_HOME/cmake/$ANDROID_CMAKE/bin:$PATH" core_for android
      (cd "$ROOT/flutter/app" && "$FLUTTER" pub get && "$FLUTTER" build apk --release --split-per-abi $(flutter_defines))
      for f in "$ROOT"/flutter/app/build/app/outputs/flutter-apk/app-*-release.apk; do
        abi=$(basename "$f" | sed -E 's/app-(.*)-release.apk/\1/')
        cp "$f" "$DIST/TwimShelf-Flutter-$v-android-$abi.apk"
      done ;;
    electron-linux)
      [[ $OS == Linux ]] || fail "electron-linux builds on Linux"
      build_electron linux
      cp "$ELECTRON_OUT"/TwimShelf-*.AppImage "$DIST/" ;;
    electron-macos)
      # for testing the Linux app's UI on a Mac: not built by default, not published
      [[ $OS == Darwin ]] || fail "electron-macos builds on macOS"
      build_electron mac
      rm -rf "$DIST/TwimShelf Electron.app"; cp -R "$ELECTRON_OUT"/mac*/TwimShelf.app "$DIST/TwimShelf Electron.app" ;;
    docker|docker-cuda)
      # the Linux server and the web app; everything is compiled inside the image, so this
      # computer needs only Docker (its own build cache stays in Docker's storage). The AI's GPU:
      # Vulkan (AMD, Intel), or CUDA (NVIDIA, amd64; NVIDIA's images are several GB)
      have docker || fail "Docker is needed: https://docs.docker.com/get-docker/ (or OrbStack, Colima)"
      local gpu=(--build-arg GPU=vulkan) tag=""
      if [[ $t == docker-cuda ]]; then
        local cuda; cuda=$(sed -nE 's/^ARG CUDA_VERSION=(.+)$/\1/p' "$ROOT/docker/Dockerfile")
        gpu=(--platform linux/amd64 --build-arg GPU=cuda --build-arg RUNTIME="nvidia/cuda:$cuda-runtime-ubuntu24.04"); tag=-cuda
      fi
      docker build -f "$ROOT/docker/Dockerfile" "${gpu[@]}" --build-arg VERSION="$v" --build-arg RUST_VERSION="$RUST_TOOLCHAIN" --build-arg NODE_VERSION="$(tr -d ' \n' < "$ROOT/.node-version")" -t "twimshelf:$v$tag" -t "twimshelf:latest$tag" "$ROOT"
      local arch; arch=$(docker image inspect --format '{{.Architecture}}' "twimshelf:$v$tag")
      docker save "twimshelf:$v$tag" | gzip > "$DIST/TwimShelf-$v-docker$tag-linux-$arch.tar.gz" ;;
    windows) fail "the Windows app (native, WinUI 3) builds on Windows: build.ps1 windows" ;;
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
flutter-ios      the Flutter iPhone/iPad app (.ipa)        macOS with Xcode
flutter-android  the Flutter Android app (.apk per ABI)    macOS or Linux (Windows: build.ps1)
electron-linux   the Linux desktop app, React + Electron (.AppImage)  Linux
windows          the native Windows app (setup .exe)       Windows: build.ps1
docker           the Linux server + web app (image, .tar.gz) any computer with Docker (not built by default)
docker-cuda      the same, with NVIDIA (CUDA) AI, amd64      any computer with Docker (not built by default)
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
      flutter-ios) need_xcode; need_rust; need_flutter; need_flutter_apple ;;
      flutter-android) need_rust; need_flutter; need_android ;;
      electron-*) need_rust; need_node ;;
      docker|docker-cuda) have docker || MISSING+=(Docker) ;;
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
