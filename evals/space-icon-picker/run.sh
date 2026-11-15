#!/bin/bash
# Builds the debug binary, then pictures the space icon picker into
# $YAB_FARM_OUT (or ./work/space-icon-picker).
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --product Fast 2>&1 | tail -20
python3 evals/space-icon-picker/shots.py --bin .build/debug/Fast --out "${YAB_FARM_OUT:-work/space-icon-picker}"
