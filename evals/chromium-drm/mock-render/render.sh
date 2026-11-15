#!/bin/bash
# Farm only: renders the Opens in mockup page headless. Not a Yab check.
set -euo pipefail
cd "$(dirname "$0")"
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$C" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$YAB_FARM_OUT/chrome" \
  --force-device-scale-factor=2 --window-size=1300,7600 \
  --screenshot="$YAB_FARM_OUT/opens-in.png" "file://$PWD/opens-in.html"
ls -la "$YAB_FARM_OUT"
