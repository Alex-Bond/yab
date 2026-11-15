#!/bin/bash
# Exercise the production routing block and catalog against the pinned CEF enums.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
if [ -z "${YAB_CEF_DIR:-}" ]; then
  YAB_CEF_DIR="$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+d["sdkKey"]+"/"+d["distribution"])')"
fi
python3 - "$YAB_FARM_OUT/permission-masks.mm" <<'PY'
from pathlib import Path
import sys
catalog = Path('YabCore/src/permissions.inc').read_text()
route = Path('YabCore/src/questions.inc').read_text()
bits = catalog[catalog.index('struct GrantBit'):catalog.index('static CefRefPtr<CefRequestContext> GrantContext')]
route = route[route.index('  NSString* kind = nil;'):route.index('  NSString* top =')]
# Stop before refusal delivery: the test observes the selected kind itself.
route = route[:route.index('  // A feature with nothing')]
source = '''#import <Foundation/Foundation.h>
#include <cassert>
#include "include/internal/cef_types.h"
'''+bits+'''
static NSString* classify(uint32_t mask, NSMutableArray<NSString*>* asked) {
'''+route.replace('  NSMutableArray<NSString*>* asked = [NSMutableArray array];\n', '')+'''
  return kind;
}
int main() { @autoreleasepool {
  struct Mapping { uint32_t bit; NSString* name; };
  for (const auto& mapping : {Mapping{CEF_PERMISSION_TYPE_LOCAL_FONTS, @"fonts"},
                             Mapping{CEF_PERMISSION_TYPE_LOCAL_NETWORK, @"local-network"},
                             Mapping{CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, @"loopback-network"}}) {
    auto asked = [NSMutableArray<NSString*> array];
    assert([classify(mapping.bit, asked) isEqual:@"permission"] && asked.count == 1);
    assert([asked.firstObject isEqual:mapping.name]);
  }
  assert(classify(0, [NSMutableArray<NSString*> array]) == nil);
  uint32_t unknown = CEF_PERMISSION_TYPE_AR_SESSION;
  auto asked = [NSMutableArray<NSString*> array];
  assert(classify(unknown, asked) == nil);
  assert(classify(unknown | CEF_PERMISSION_TYPE_LOCAL_FONTS, asked) == nil);
  assert(classify(CEF_PERMISSION_TYPE_GEOLOCATION | CEF_PERMISSION_TYPE_LOCAL_FONTS, asked) == nil);
  assert([classify(CEF_PERMISSION_TYPE_LOCAL_NETWORK | CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, asked) isEqual:@"permission"]);
  assert([classify(CEF_PERMISSION_TYPE_GEOLOCATION, asked) isEqual:@"location"]);
  assert([classify(CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM, asked) isEqual:@"capture"]);
  puts("PASS native permission masks: fonts, network, loopback, combined, unknown, partially mapped");
} }
'''
Path(sys.argv[1]).write_text(source)
PY
clang++ -std=c++20 -fobjc-arc -framework Foundation -I "$YAB_CEF_DIR" -DCEF_API_VERSION=999999 \
  "$YAB_FARM_OUT/permission-masks.mm" -o "$YAB_FARM_OUT/permission-masks"
"$YAB_FARM_OUT/permission-masks"
