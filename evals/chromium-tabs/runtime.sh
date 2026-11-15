#!/bin/bash
# Reuse an exact signed build for harness-only changes. Run on the farm.
set -euo pipefail
cd "$(dirname "$0")/../.."
SOURCE_APP="$1"
ARTIFACT="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" \
    --report "$YAB_FARM_OUT/python-dependencies.json" Pillow
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
ditto "$SOURCE_APP" "$ARTIFACT"
ACTUAL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ARTIFACT/Contents/Info.plist")"
test "$ACTUAL" = "$YAB_TASK_NAME"
printf '%s\n' "$ACTUAL" > "$YAB_FARM_OUT/app-name.txt"
printf '%s\n' "$ARTIFACT" > "$YAB_FARM_OUT/yab-app-path.txt"
codesign --verify --deep --strict "$ARTIFACT"
python3 -u evals/chromium-tabs/run.py --app "$ARTIFACT" --out "$YAB_FARM_OUT/acceptance"
