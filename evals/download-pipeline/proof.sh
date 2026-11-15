#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${YAB_FARM_OUT:?run through the shared farm}
task_name=${YAB_TASK_NAME:?a task name is required}

# One development app, reused for every native action/transfer probe below.
# No release, publishing, version bump or normal user-profile launch.
./build.sh
app="$out/$task_name.app"
ditto "build/yab Dev.app" "$app"
python3 - "$app/Contents/Info.plist" "$task_name" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleName'] == sys.argv[2]
assert info['CFBundleDisplayName'] == sys.argv[2]
print('Delivered app name verified:', sys.argv[2], flush=True)
PY
codesign --verify --deep --strict "$app"
export APP="$app"
python3 -u evals/golden/download_image_menu.py --app "$app" --out "$out/image-menu"
python3 -u evals/downloads-1545/check.py --app "$app" --tag pipeline --out "$out/download-matrix"
python3 -u evals/download-stuck/check.py --app "$app"
