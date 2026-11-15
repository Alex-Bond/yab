#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec /opt/homebrew/bin/python3 -u evals/horizontal-wheel/run.py "${1:?main revision required}"
