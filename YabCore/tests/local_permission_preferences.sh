#!/bin/bash
# The real preference seeder, run on a profile left blocked by an old helper.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
python3 - "$YAB_FARM_OUT/local-permission-preferences.mm" <<'PY'
from pathlib import Path
import os, subprocess, sys
revision=os.environ.get('YAB_PERMISSION_BASE')
s=(subprocess.check_output(['git','show',revision+':YabCore/src/clear_data.inc'],text=True)
   if revision else Path('YabCore/src/clear_data.inc').read_text())
s=s[:s.index('// Chromium\'s own data removal')]
Path(sys.argv[1]).write_text('''#import <Foundation/Foundation.h>
#include <cassert>
'''+s+'''
int main(int argc, const char** argv) { @autoreleasepool {
  NSString* path = @(argv[1]);
  NSDictionary* blocked = @{@"https://old.example:8443,*": @{@"setting": @2}};
  NSDictionary* initial = @{@"profile": @{@"content_settings": @{@"exceptions": @{
    @"local_fonts": blocked, @"local_network_access": blocked, @"local_network": blocked, @"loopback_network": blocked,
    @"notifications": blocked}}}, @"unrelated": @"kept"};
  [[NSJSONSerialization dataWithJSONObject:initial options:0 error:nil] writeToFile:path atomically:YES];
  SeedPreferences(path);
  NSDictionary* read = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
  NSDictionary* exceptions = read[@"profile"][@"content_settings"][@"exceptions"];
  for (NSString* kind in @[@"local_fonts", @"local_network_access", @"local_network", @"loopback_network"])
    assert([exceptions[kind] isEqual:@{}]);
  assert([exceptions[@"notifications"] isEqual:blocked]);
  assert([read[@"unrelated"] isEqual:@"kept"]);
  puts("PASS legacy native font/network blocks cleared before Yab restores its decisions");
} }
''')
PY
clang++ -std=c++20 -fobjc-arc -framework Foundation "$YAB_FARM_OUT/local-permission-preferences.mm" -o "$YAB_FARM_OUT/local-permission-preferences"
"$YAB_FARM_OUT/local-permission-preferences" "$YAB_FARM_OUT/legacy-permission-preferences.json"
