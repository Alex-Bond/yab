#!/bin/bash
# A right click in an extension action popup that closes under its menu,
# against the pinned release SDK (cef-patches/popup-context-menu-probe.py).
# Crashes on an SDK without cef-patches/0105 (reports 1100-1539); clean with it.
# Submit with --display; YAB_CEF_DIR picks another SDK.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
source YabCore/tests/release_core_app.sh || exit 1
lockf -k -s "${YAB_BUILD_LOCK:-/tmp/yab-build.lock}" clang++ -std=c++20 -fobjc-arc \
  -framework Cocoa -framework QuartzCore YabCore/tests/external_action_host.mm -o "$YAB_FARM_OUT/external-action-host" || exit 1
python3 -u YabCore/cef-patches/popup-context-menu-probe.py --app "$APP" --host "$YAB_FARM_OUT/external-action-host"
