#!/bin/sh
# Renders any SVG design here to a 1024 px PNG (the format of the repository's icon.png: square,
# with its own corners and a transparent margin) and the preview sheet, with the Chrome already installed.
#   sh icon-design/render.sh
set -e
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p out
for svg in *.svg; do
  [ -e "$svg" ] || continue
  name="${svg%.svg}"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$PWD/out/$name.png" "file://$PWD/$svg" >/dev/null 2>&1
  echo "out/$name.png"
done
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1240,780 \
  --screenshot="$PWD/out/preview.png" "file://$PWD/preview.html" >/dev/null 2>&1
echo "out/preview.png"
