#!/bin/bash
# Append to the coordinator's existing combined job; no standalone farm submit.
set -euo pipefail
: "${YAB_FARM_OUT:?Run inside the existing coordinator farm job}"
cd "$(dirname "$0")/../.."
pdf_owner_cxx="${CXX:-clang++}"
"$pdf_owner_cxx" -std=c++20 -IYabCore/src YabCore/tests/original_pdf_presence_owner_test.cc \
  -o "$YAB_FARM_OUT/original-pdf-presence-owner"
"$YAB_FARM_OUT/original-pdf-presence-owner"
