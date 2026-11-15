#!/bin/bash
# Build the given commit (main as it is, not the dirty tree) and shoot it.
set -euo pipefail
cd "$(dirname "$0")/../.."
rev=${1:-HEAD}
out=${YAB_FARM_OUT:?run through farm}
apps="$out/apps"
mkdir -p "$apps"
bash scripts/runs/rev_app.sh "$rev" "$apps/base.app" 2>&1 | tee "$out/build.log"
python3 -u evals/private-look/shots.py --app "$apps/base.app" --out "$out/shots"
