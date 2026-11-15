#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
FILTER="$(python3 scripts/runs/tests_for.py Sources/Fast/ChromiumPrivateProfiles.swift Sources/Fast/EngineSwitchGlobal.swift Sources/Fast/ChromiumDRMCookies.swift Sources/Fast/ChromiumDRMExtensions.swift Sources/Fast/ChromiumExtensions.swift Sources/Fast/ChromiumTabAdoption.swift Sources/Fast/ChromiumPage.swift Sources/Fast/ChromiumDRMBench.swift Sources/Fast/PageOwnership.swift Sources/Fast/SiteEngine.swift Sources/Fast/Tab.swift Tests/FastTests/ChromiumPrivateProfilesTests.swift Tests/FastTests/TabEngineTests.swift)"
printf '%s\n' "$FILTER" > "$YAB_FARM_OUT/test-filter.txt"
bash evals/chromium-tabs/tests.sh "${FILTER}|ChromiumPrivateProfilesTests|ChromiumTabAdoptionTests|TabEngineTests"
