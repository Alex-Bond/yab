#!/bin/bash
# Farm only: ./farm exec --display --needs capture,pointer,accessibility --name "…" -- \
#   bash evals/chromium-switch/choose.sh HOST:/path/to/App.app
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?Run through farm}"
SOURCE="${1:?HOST:/path/to/App.app}"
NAME="$(basename "${SOURCE#*:}")"
CACHE="$HOME/.local/state/yab-chromium-r1/apps/$(printf '%s' "$SOURCE" | shasum | cut -c1-12)"
mkdir -p "$CACHE"
case "$SOURCE" in
  /*) ;;  # Already on this Mac: run it where it is.
  *) bash YabCore/cef-patches/fetch-native-artifact.sh "$CACHE/" "${SOURCE%/}" || exit 1 ;;
esac
APP="$CACHE/$NAME"
case "$SOURCE" in /*) APP="${SOURCE%/}" ;; esac
codesign --verify --deep --strict "$APP" || exit 1
PYDIR="$HOME/.local/state/yab-chromium-r1/python"
export PYTHONPATH="$PYDIR${PYTHONPATH:+:$PYTHONPATH}"
python3 -c 'from PIL import Image' >/dev/null 2>&1 \
  || python3 -m pip install --disable-pip-version-check --target "$PYDIR" Pillow
if ! python3 -c 'import ScreenCaptureKit' >/dev/null 2>&1; then
  BRIDGE_VERSION="$(python3 -c 'import objc; print(objc.__version__)')"
  python3 -m pip install --disable-pip-version-check --no-deps --target "$PYDIR" "pyobjc-framework-ScreenCaptureKit==$BRIDGE_VERSION"
fi
exec python3 -u evals/chromium-switch/choose.py --app "$APP" --out "$YAB_FARM_OUT/choose"
