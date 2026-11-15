#!/bin/bash
# Before/after: the fix's parent and this tree, the same local search pages.
set -euo pipefail
cd "$(dirname "$0")/../.."
base="${1:?baseline rev, e.g. 967f17533^}"
out="${YAB_FARM_OUT:?}"
pair="$(mktemp -d "$(dirname "${APP:?run through farm}")/search-title.XXXXXX")"
./build.sh 2>&1 | tee "$out/candidate-build.log"
ditto "build/yab Dev.app" "$pair/this.app"
py=/opt/homebrew/bin/python3; [ -x "$py" ] || py=python3  # m2pro has no Homebrew
bash scripts/runs/rev_app.sh "$base" "$pair/base.app" 2>&1 | tee "$out/baseline-build.log"
"$py" evals/search-title/check.py --base-app "$pair/base.app" --app "$pair/this.app"
