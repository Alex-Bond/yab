#!/bin/bash
# Unsigned product/test compile and mapped tests, without a signed CEF build.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "$#" -gt 0 ]]; then
    TOUCHED=("$@")
else
    TOUCHED=(Sources/Fast/Agent*.swift Sources/Fast/ChromiumPage.swift Sources/Fast/ChromiumPage+Agent*.swift
             Sources/Fast/Headless.swift Tests/FastTests/AgentPageRoutingTests.swift Tests/FastTests/AgentSecretsTests.swift)
fi
export CHROMIUM_SCRIPTS_TEST_FILTER="$(python3 scripts/runs/tests_for.py "${TOUCHED[@]}")"
# CommitWordsTests shares ReleaseGuardsTests.swift and is invisible to the
# filename-based mapper. Include the existing payment/language regressions.
if [[ " ${TOUCHED[*]} " == *" Sources/Fast/AgentPermit.swift "* ]]; then
    export CHROMIUM_SCRIPTS_TEST_FILTER="$CHROMIUM_SCRIPTS_TEST_FILTER|ReleaseGuardsTests|CommitWordsTests"
fi
printf '%s\n' "$CHROMIUM_SCRIPTS_TEST_FILTER" > "$YAB_FARM_OUT/test-filter.txt"
bash evals/chromium-agents/native.sh
