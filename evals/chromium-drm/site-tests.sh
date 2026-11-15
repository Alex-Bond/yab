#!/bin/bash
# Farm-only native proof for the site-engine model. No CEF app build or release.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DRM_TEST_FILTER="$(python3 scripts/runs/tests_for.py \
  Sources/Fast/SiteEngine.swift Sources/Fast/PageOwnership.swift \
  Sources/Fast/Tab.swift Sources/Fast/WebKitBrowser.swift \
  Sources/Fast/ChromiumPage.swift Sources/Fast/ChromiumDRMBench.swift \
  Tests/FastTests/SiteEngineTests.swift Tests/FastTests/TabEngineTests.swift)"
printf '%s\n' "$DRM_TEST_FILTER" > "$YAB_FARM_OUT/selected-tests.txt"
bash evals/chromium-drm/tests.sh
