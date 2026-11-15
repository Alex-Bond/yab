#!/bin/bash
# Harness-only rerun of an exact retained signed app. No build or re-signing.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?Run through the farm}"
SOURCE_APP="${1:?Exact retained app required}"
APP_SHA="${2:?Expected app executable SHA-256 required}"
CORE_SHA="${3:?Expected YabCore SHA-256 required}"
APP="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
python3 - "$SOURCE_APP" "$APP_SHA" "$CORE_SHA" <<'PY'
import hashlib, os, plistlib, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleName'] == info['CFBundleDisplayName'] == os.environ['YAB_TASK_NAME']
for relative, expected in [(info['CFBundleExecutable'], sys.argv[2]), ('YabCore', sys.argv[3])]:
    assert len(expected) == 64 and all(c in '0123456789abcdef' for c in expected)
    binary = app / 'Contents/MacOS' / relative
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == expected, str(binary)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, timeout=60)
PY
ditto "$SOURCE_APP" "$APP"
printf '%s\n' "$APP" > "$YAB_FARM_OUT/yab-app-path.txt"
trap 'python3 evals/chromium-scripts/ownership.py "$YAB_FARM_OUT"' EXIT
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
    python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" Pillow
    export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
shift 3
if [[ "${1:-}" == --lifecycle ]]; then
    shift
    python3 -u evals/chromium-agents/lifecycle.py --app "$APP" --out "$YAB_FARM_OUT/lifecycle" "$@"
    exit
fi
WITH_LIFECYCLE=0
if [[ "${1:-}" == --with-lifecycle ]]; then WITH_LIFECYCLE=1; shift; fi
if [[ "$#" -eq 0 ]]; then set -- --security; fi
RESULT=0
python3 -u evals/chromium-agents/run.py --app "$APP" --out "$YAB_FARM_OUT/agents" "$@" || RESULT=1
if [[ "$WITH_LIFECYCLE" -eq 1 ]]; then
    python3 -u evals/chromium-agents/lifecycle.py --app "$APP" --out "$YAB_FARM_OUT/lifecycle" || RESULT=1
fi
exit "$RESULT"
