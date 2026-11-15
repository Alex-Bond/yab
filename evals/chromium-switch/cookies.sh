#!/bin/bash
# Farm only: signed app, real helper, synthetic cookies and SCK proof.
set -euo pipefail
cd "$(dirname "$0")/../.."
export NAV_SKIP_TEST_BUILD=1
bash evals/chromium-nav/build_print_find.sh
APP="$(cat "$YAB_FARM_OUT/app-path.txt")"
if ! python3 -c 'from PIL import Image; import ScreenCaptureKit' >/dev/null 2>&1; then
  BRIDGE_VERSION="$(python3 -c 'import objc; print(objc.__version__)')"
  python3 -m pip install --disable-pip-version-check --target "$YAB_FARM_OUT/python" Pillow "pyobjc-framework-ScreenCaptureKit==$BRIDGE_VERSION"
  export PYTHONPATH="$YAB_FARM_OUT/python${PYTHONPATH:+:$PYTHONPATH}"
fi
python3 -u evals/chromium-nav/deadline.py 540 evals/golden/chromium_engine_switch.py --app "$APP" --out "$YAB_FARM_OUT/cookies"
