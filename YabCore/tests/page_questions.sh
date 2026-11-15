#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
clang++ -std=c++20 -fobjc-arc -framework Foundation -I YabCore/tests/fakes \
  YabCore/tests/page_questions_test.mm -o "$YAB_FARM_OUT/page-questions-test"
"$YAB_FARM_OUT/page-questions-test"
