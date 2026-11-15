#!/bin/bash
# Reconciliation proof: unsigned native helper, product and mapped tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$YAB_FARM_OUT/core"
YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh > "$YAB_FARM_OUT/core-app.txt"
bash evals/chromium-agents/batch.sh "$@"
