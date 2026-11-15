#!/bin/bash
# Frozen four-file fix for the A/B, independent of later parallel edits.
set -euo pipefail
git -C "${1:?revision tree}" apply --unidiff-zero "$(pwd)/evals/settings-links/fix.patch"
