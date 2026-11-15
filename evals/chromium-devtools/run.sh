#!/bin/bash
# ./farm exec --display --needs capture,foreground,pointer --name "…" -- \
#   bash evals/chromium-devtools/run.sh HOST:/path/App.app [scenario,…]
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?Run through farm}"
SOURCE="${1:?HOST:/path/to/App.app}"
ONLY="${2:-}"
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
if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  PYDIR="$HOME/.local/state/yab-chromium-r1/python"
  python3 -c "import sys; sys.path.insert(0, '$PYDIR'); from PIL import Image" >/dev/null 2>&1 \
    || python3 -m pip install --disable-pip-version-check --target "$PYDIR" Pillow
  export PYTHONPATH="$PYDIR${PYTHONPATH:+:$PYTHONPATH}"
fi
python3 -u evals/chromium-devtools/run.py --app "$APP" --out "$YAB_FARM_OUT/devtools" --only "$ONLY"
