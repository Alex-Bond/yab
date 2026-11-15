#!/bin/bash
# Farm only. Read integration objects into a fresh directory, never checkout.
set -euo pipefail
cd "$(dirname "$0")/../.."
REV="${1:?integration revision required}"
export YAB_FARM_JOB="${YAB_FARM_JOB:-drm-integration-baseline}"
export DRM_TEST_FILTER="$(python3 scripts/runs/tests_for.py Sources/Fast/SiteEngine.swift Sources/Fast/PageOwnership.swift Sources/Fast/ChromiumDRM.swift Sources/Fast/ChromiumDRMCookies.swift Sources/Fast/ChromiumDRMExtensions.swift Sources/Fast/ChromiumDRMExtensionScripts.swift Sources/Fast/ChromiumDRMExtensionRules.swift Sources/Fast/ChromiumDRMNavigation.swift Sources/Fast/ChromiumProcess.swift Sources/Fast/WebKitBrowser.swift Sources/Fast/ChromiumDRMBench.swift Sources/Fast/ChromiumPage.swift Sources/Fast/Tab.swift Sources/Fast/Bench.swift Tests/FastTests/SiteEngineTests.swift Tests/FastTests/TabEngineTests.swift Tests/FastTests/ChromiumDRMTests.swift Tests/FastTests/ChromiumDRMExtensionTests.swift Tests/FastTests/ChromiumDRMNavigationTests.swift Tests/FastTests/ChromiumPageTests.swift)"
git rev-parse "$REV^{commit}" > "$YAB_FARM_OUT/baseline-revision.txt"
git archive "$REV" > "$YAB_FARM_OUT/baseline.tar"
mkdir "$YAB_FARM_OUT/baseline"
tar -xf "$YAB_FARM_OUT/baseline.tar" -C "$YAB_FARM_OUT/baseline"
cd "$YAB_FARM_OUT/baseline"
mkdir -p "$YAB_FARM_OUT/isolated" "$YAB_FARM_OUT/broad"
set +e
YAB_FARM_OUT="$YAB_FARM_OUT/isolated" DRM_TEST_FILTER=TabRenameTests bash evals/chromium-drm/tests.sh
ISOLATED=$?
YAB_FARM_OUT="$YAB_FARM_OUT/broad" bash evals/chromium-drm/tests.sh
BROAD=$?
set -e
printf 'isolated=%s\nbroad=%s\n' "$ISOLATED" "$BROAD" > "$YAB_FARM_OUT/baseline-status.txt"
exit "$((ISOLATED || BROAD))"
