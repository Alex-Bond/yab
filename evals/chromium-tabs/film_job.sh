#!/bin/bash
# Build Yab with the YabCore helper (prebuilt CEF unless YAB_CEF_DIR is set)
# and film a window resize. Run as one farm display job pinned off main.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$YAB_FARM_OUT/core"
CORE_APP="$(YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh)"
YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/YabCore" ./build.sh
ARTIFACT="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
ditto 'build/yab Dev.app' "$ARTIFACT"
bash evals/chromium-tabs/film.sh "$ARTIFACT"
