#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?run through the shared farm}"
python3 -u evals/golden/tidy_download_names.py
