#!/bin/bash
# Farm only. Keep both supplied acceptance results even if one phase fails.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT_OUT="$YAB_FARM_OUT"
mkdir -p "$ROOT_OUT/drm" "$ROOT_OUT/opens"
DRM_STATUS=0
YAB_FARM_OUT="$ROOT_OUT/drm" bash evals/chromium-drm/job.sh || DRM_STATUS=$?
OPENS_STATUS=0
YAB_FARM_OUT="$ROOT_OUT/opens" bash evals/chromium-drm/opens-in-job.sh || OPENS_STATUS=$?
printf 'drm=%s\nopens=%s\n' "$DRM_STATUS" "$OPENS_STATUS" > "$ROOT_OUT/acceptance-status.txt"
for phase in drm opens; do
  codesign --verify --deep --strict "$ROOT_OUT/$phase/$YAB_TASK_NAME.app"
  codesign -dv --verbose=4 "$ROOT_OUT/$phase/$YAB_TASK_NAME.app" 2> "$ROOT_OUT/$phase/signature.txt"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ROOT_OUT/$phase/$YAB_TASK_NAME.app/Contents/Info.plist" > "$ROOT_OUT/$phase/display-name.txt"
  if ! grep -qx 'TeamIdentifier=25UG4QYN9F' "$ROOT_OUT/$phase/signature.txt"; then
    echo "Missing Developer ID signature for $phase" >&2
    exit 1
  fi
done
exit "$((DRM_STATUS || OPENS_STATUS))"
