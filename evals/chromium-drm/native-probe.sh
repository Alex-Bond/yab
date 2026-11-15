#!/bin/bash
# Farm-only diagnostic without the outer app's signing/Swift build.
set -euo pipefail
cd "$(dirname "$0")/../.."
CORE_APP="$(bash YabCore/build.sh)"
python3 -u evals/chromium-drm/native-probe.py --app "$CORE_APP" --out "$YAB_FARM_OUT/native-probe"
