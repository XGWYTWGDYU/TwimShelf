#!/usr/bin/env bash
# package_dmg.sh <App.app> <out.dmg>: a disk image with the app and a link to Applications.
set -euo pipefail
app=$1 out=$2
[[ -d "$app" ]] || { echo "No app at $app" >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$out"
hdiutil create -volname "$(basename "$app" .app)" -srcfolder "$stage" -ov -format UDZO "$out" >/dev/null
echo "$out"
