#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ulimit -c 0
# The real branch base, not the candidate with selected lines reverted.
python3 - "$YAB_FARM_OUT/baseline-registry.inc" <<'PY'
import subprocess,sys
s=subprocess.check_output(['git','show','aae1de5763ab67def208eb53d3af81e4c7eea2a9:YabCore/src/questions.inc'],text=True)
a=s[:s.index('static bool AskMedia(')].replace('#include "media_permission_route.h"\n','')
b=s[s.index('static void DismissPermission('):s.index('static void AskAuthentication(')]
open(sys.argv[1],'w').write(a+b)
PY
clang++ -std=c++20 -fobjc-arc -framework Foundation -I YabCore/tests/fakes \
  -DQUESTION_REGISTRY="\"$YAB_FARM_OUT/baseline-registry.inc\"" \
  YabCore/tests/page_questions_test.mm -o "$YAB_FARM_OUT/baseline-test"
set +e
"$YAB_FARM_OUT/baseline-test" > "$YAB_FARM_OUT/baseline-test.log" 2>&1
baseline=$?
set -e
cat "$YAB_FARM_OUT/baseline-test.log"
if [ "$baseline" = 0 ]; then echo 'FAIL regression did not fail on base'; exit 1; fi
grep -q 'replies == 0 && pageQuestions.size() == 1' "$YAB_FARM_OUT/baseline-test.log"
echo "PASS original base fails deferred reply assertion (exit $baseline)"
bash YabCore/tests/page_questions.sh
