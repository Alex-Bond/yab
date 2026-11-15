#!/bin/bash
# Run as one farm display job pinned off main. No release operations.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$YAB_FARM_OUT/core"
CORE_APP="$(YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh)"
YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/YabCore" ./build.sh
# The source diff is checked locally with ./design-check --head.
# Worker caches can contain unrelated non-UTF8 generated diffs.
swift test --package-path YabCore/Client --scratch-path "$YAB_FARM_OUT/client-tests" 2>&1 | tee "$YAB_FARM_OUT/client-tests.log"
bash evals/chromium-tabs/runtime.sh 'build/yab Dev.app'
