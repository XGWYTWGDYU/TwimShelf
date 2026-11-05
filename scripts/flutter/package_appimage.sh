#!/usr/bin/env bash
# package_appimage.sh <bundle dir> <output dir> <version>: the Linux app as one AppImage.
# The AppImage is the whole program (uninstalling = deleting the file); the app adds its own
# menu entry and icon to ~/.local/share on first start and removes them when asked to.
set -euo pipefail
bundle=$(cd "$1" && pwd) out=$2 version=$3
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="$(python3 "$ROOT/scripts/apply.py" where cache)/sdk"
arch=$(uname -m)
tool="$TOOLS/appimagetool-$arch.AppImage"
if [[ ! -x "$tool" ]]; then
  echo "appimagetool is not here yet (about 10 MB): $tool"
  if [[ ${TL_YES:-0} != 1 ]]; then
    read -r -p "Download it from github.com/AppImage/appimagetool? [y/N] " a
    [[ $a == y || $a == Y ]] || exit 1
  fi
  mkdir -p "$TOOLS"
  curl -fL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$arch.AppImage"
  chmod +x "$tool"
fi
app=$(mktemp -d "${TMPDIR:-/tmp}/appdir.XXXXXX")
trap 'rm -rf "$app"' EXIT
cp -a "$bundle/." "$app/"
id=$(basename "$(ls "$bundle"/share/applications/*.desktop | head -1)" .desktop)
cp "$bundle/share/applications/$id.desktop" "$app/$id.desktop"
cp "$bundle/share/icons/hicolor/256x256/apps/$id.png" "$app/$id.png"
cat > "$app/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/twimshelf" "$@"
RUN
chmod +x "$app/AppRun"
mkdir -p "$out"
target="$out/TwimShelf-Flutter-$version-linux-$arch.AppImage"
ARCH=$arch APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --no-appstream "$app" "$target"
echo "$target"
