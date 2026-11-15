#!/bin/bash
# Build main and the scoped SpaceSettings fix without other working changes.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?base commit required}
out="${YAB_FARM_OUT:?run through farm}/space-creation-search"
mkdir -p "$out"
bash scripts/runs/rev_app.sh "$base" "$out/before.app" 2>&1 | tee "$out/before-build.log"
bash scripts/runs/rev_app.sh "$base" "$out/after.app" --with Sources/Fast/SpaceSettings.swift 2>&1 | tee "$out/after-build.log"
python3 -u evals/golden/space_creation_search.py --base-app "$out/before.app" --app "$out/after.app" --out "$out/proof"
