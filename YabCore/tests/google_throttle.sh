#!/bin/bash
# One farm display job: baseline sources, then the changed helper, both signed.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
: "${YAB_FARM_OUT:?Run through farm}"
BASE=077f096955c73070b54726d6062cdf49e1a528f6
mkdir -p "$YAB_FARM_OUT/base-tree" "$YAB_FARM_OUT/before" "$YAB_FARM_OUT/after"
git archive "$BASE" YabCore scripts/cef | tar -x -C "$YAB_FARM_OUT/base-tree"
(
  cd "$YAB_FARM_OUT/base-tree"
  YAB_FARM_OUT="$YAB_FARM_OUT/before" bash YabCore/build.sh
)
python3 -u evals/golden/google_throttle.py --app "$(cat "$YAB_FARM_OUT/before/app-path.txt")" --out "$YAB_FARM_OUT/before/probe" --expect-crash
(
  YAB_FARM_OUT="$YAB_FARM_OUT/after" bash YabCore/build.sh
)
python3 -u evals/golden/google_throttle.py --app "$(cat "$YAB_FARM_OUT/after/app-path.txt")" --out "$YAB_FARM_OUT/after/probe"
