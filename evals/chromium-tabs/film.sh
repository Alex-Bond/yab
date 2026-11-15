#!/bin/bash
# Resize film of an exact signed build. Run on the farm with --display.
set -euo pipefail
cd "$(dirname "$0")/../.."
SOURCE_APP="$1"
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" Pillow
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
codesign --verify --deep --strict "$SOURCE_APP"
python3 -u evals/chromium-tabs/resize_film.py --app "$SOURCE_APP" --out "$YAB_FARM_OUT/film"
