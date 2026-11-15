#!/bin/bash
# Harness-only retry on the exact signed artifact. No rebuild or re-signing.
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="$1"
shift
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" = "$YAB_TASK_NAME"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist")" = "$YAB_TASK_NAME"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP" > "$YAB_FARM_OUT/app-source-path.txt"
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" Pillow
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
python3 -u evals/chromium-drm/run.py --app "$APP" --out "$YAB_FARM_OUT/acceptance" "$@"
