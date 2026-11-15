#!/bin/bash
# Early compiler feedback while the independent signed runtime wave waits.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$YAB_FARM_OUT/core"
YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh > "$YAB_FARM_OUT/core-app.txt"
export CHROMIUM_SCRIPTS_COMPILE_ONLY=1
bash evals/chromium-scripts/tests.sh
