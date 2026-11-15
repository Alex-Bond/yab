#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app=${1:?an already built app is required}
out=${YAB_FARM_OUT:?run through the shared farm}
codesign --verify --deep --strict "$app"
export APP="$app"
python3 -u evals/golden/download_image_menu.py --app "$app" --out "$out/image-menu"
python3 -u evals/downloads-1545/check.py --app "$app" --tag pipeline --out "$out/download-matrix"
python3 -u evals/download-stuck/check.py --app "$app"
