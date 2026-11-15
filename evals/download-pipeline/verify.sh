#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash evals/download-pipeline/tests.sh
bash evals/download-pipeline/proof.sh
