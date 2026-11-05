#!/usr/bin/env bash
# package_ipa.sh <App.app> <out.ipa>: an unsigned .ipa (sign it with your own certificate, or
# install it with a sideloading tool).
set -euo pipefail
app=$1 out=$2
[[ -d "$app" ]] || { echo "No app at $app" >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/ipa.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
cp -R "$app" "$stage/Payload/"
rm -f "$out"
dest="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
(cd "$stage" && zip -qry "$dest" Payload)
echo "$out"
