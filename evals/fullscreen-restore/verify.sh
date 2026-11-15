#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?main revision before this fix}
out=${YAB_FARM_OUT:?run through the farm}
if [ -n "${2:-}" ] && [ -d "$2" ]; then
    # Reuse the exact untouched baseline already built by a previous job.
    ditto "$2" "$out/before.app"
else
    bash scripts/runs/rev_app.sh "$base" "$out/before.app"
fi
python3 -u evals/golden/fullscreen_restore.py --app "$out/before.app" --out "$out/before" --baseline
bash scripts/runs/rev_app.sh "$base" "$out/after.app" \
    --with Sources/Fast/BrowserWindows.swift --with Sources/Fast/WindowFullscreen.swift \
    --with Sources/Fast/FieldBench.swift
python3 -u evals/golden/fullscreen_restore.py --app "$out/after.app" --out "$out/after"
python3 - "$out" <<'PY'
import json
from pathlib import Path
import sys
out = Path(sys.argv[1])
before = json.loads((out / 'before/report.json').read_text())
after = json.loads((out / 'after/report.json').read_text())
regressions = [row['name'] for row in before['checks'] if not row['ok']]
assert regressions, 'No bug reproduced on main; review whether the change is needed'
assert not after.get('error') and all(row['ok'] for row in after['checks'])
print('CONFIRMED before/after:', ', '.join(regressions), flush=True)
PY
