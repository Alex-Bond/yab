#!/bin/bash
# Site Controls icons, turned on and off off screen, from the real source:
#   ./farm exec --name "Site icons" -- bash evals/site-icon-motion/run.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${YAB_FARM_OUT:-$(mktemp -d)}"
# The icon as it ships, less the design module its stubs stand in for.
grep -v '^import YabDesign' "$here/../../Sources/Fast/SiteControlsIcon.swift" > "$out/SiteControlsIcon.swift"
xcrun swiftc -swift-version 5 -o "$out/icon-motion" "$here/stubs.swift" "$here/main.swift" "$out/SiteControlsIcon.swift" || exit 2
"$out/icon-motion" "$out"
