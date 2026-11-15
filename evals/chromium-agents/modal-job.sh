#!/bin/bash
# Read the exact signed helper's modal contract without rebuilding or signing.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?Run through the farm}"
case "${WHERE:-}" in adhd|renderer-2|m4) ;; *) exit 1 ;; esac
APP="${1:?Exact signed source app path required}"
if [[ ! -d "$APP" ]]; then
    # Read-only artifact transport, never an out-of-queue remote execution.
    SOURCE_APP="$APP"
    APP="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
    ADHD_HOST=adhd YAB_FARM_TRANSPORT=1 ./adhd pull "$SOURCE_APP" "$APP"
fi
python3 - "$APP" "$YAB_FARM_OUT" <<'PY'
import hashlib, json, os, plistlib, subprocess, sys
from pathlib import Path
app, out = map(Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleName'] == info['CFBundleDisplayName'] == os.environ['YAB_TASK_NAME']
receipt = {'app': str(app), 'host': os.environ['WHERE'], 'sha256': {}}
for binary in (app / 'Contents/MacOS' / info['CFBundleExecutable'], app / 'Contents/MacOS/YabCore'):
    receipt['sha256'][binary.name] = hashlib.sha256(binary.read_bytes()).hexdigest()
for code in (app, app / 'Contents/MacOS/YabCore'):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(code)], check=True, timeout=60)
    signature = subprocess.run(['codesign', '-d', '--verbose=4', str(code)], capture_output=True, text=True, check=True, timeout=60).stderr
    assert 'TeamIdentifier=25UG4QYN9F' in signature
(out / 'exact-app.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
python3 -u evals/chromium-agents/dialog_modal_probe.py --app "$APP" --out "$YAB_FARM_OUT/native-modal" --modal-probe
