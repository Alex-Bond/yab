#!/bin/bash
# Real signed app and helper. Unsigned mapped tests run separately in batch.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${WHERE:-}" in
    adhd|renderer-2|m4) ;;
    *) echo "Agent builds require a permitted remote farm worker" >&2; exit 1 ;;
esac
trap 'python3 evals/chromium-scripts/ownership.py "$YAB_FARM_OUT"' EXIT
mkdir -p "$YAB_FARM_OUT/core"
CORE_APP="$(YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh)"
YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_HELPER="$CORE_APP/Contents/MacOS/YabCore" ./build.sh
APP="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
ditto "build/yab Dev.app" "$APP"
printf '%s\n' "$APP" > "$YAB_FARM_OUT/yab-app-path.txt"
export APP
python3 - <<'PY'
import os, plistlib, subprocess
from pathlib import Path
app = Path(os.environ['APP'])
p = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert p['CFBundleName'] == p['CFBundleDisplayName'] == os.environ['YAB_TASK_NAME']
for code in (app, app / 'Contents/MacOS/YabCore'):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(code)], check=True)
    sig = subprocess.run(['codesign', '-d', '--verbose=4', str(code)], capture_output=True, text=True, check=True).stderr
    assert 'TeamIdentifier=25UG4QYN9F' in sig, sig
PY
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" Pillow
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
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
