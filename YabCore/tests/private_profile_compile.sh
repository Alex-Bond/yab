#!/bin/bash
# YabCore's side of cef-patches/0092 (a private context as a space profile's
# off-the-record side) compiled before an SDK carries the patch: the release
# SDK's headers with 0092's declaration and capability macro added, then
# core.mm (every .inc of the core is in it) checked with the build's own
# flags. Also checked as today's SDK has it, where the parent is ignored.
# Syntax and types only; nothing links. Farm only, any Mac but main.
#   ./farm exec --name "..." -- bash YabCore/tests/private_profile_compile.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
[ "${YAB_FARM_HOST:-}" != main ] || { echo 'Not on main' >&2; exit 2; }
SDK="$(python3 -c 'import json,os; d=json.load(open("scripts/cef/release-sdk.json")); print(os.path.expanduser("~/.local/state/yab-spike-cef/owncef-sdk/")+d["sdkKey"]+"/"+d["distribution"])')"
[ -f "$SDK/include/cef_request_context.h" ] || { echo "No release SDK at $SDK" >&2; exit 1; }
SHADOW="$YAB_FARM_OUT/sdk-0092"
mkdir -p "$SHADOW"
for entry in "$SDK"/*; do
  [ "$(basename "$entry")" = include ] || ln -s "$entry" "$SHADOW/$(basename "$entry")"
done
cp -R "$SDK/include" "$SHADOW/include"
python3 - "$SHADOW/include" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
def put(name, anchor, text):
    path = root / name
    source = path.read_text()
    match = re.search(anchor, source, re.S)
    assert match, (name, anchor)
    path.write_text(source[:match.end()] + text + source[match.end():])
put('cef_request_context.h', r'#define CEF_YAB_VERIFIED_CRX_VERSION 1\n',
    '#define CEF_YAB_OFF_THE_RECORD_CONTEXT_VERSION 1\n')
put('cef_request_context.h', r'virtual cef_color_variant_t GetChromeColorSchemeVariant\(\) = 0;\n',
    '#if CEF_API_ADDED(CEF_EXPERIMENTAL)\n'
    '  virtual CefRefPtr<CefRequestContext> CreateOffTheRecordContext(\n'
    '      CefRefPtr<CefRequestContextHandler> handler) = 0;\n'
    '#endif\n')
PY
CMAKE="$(command -v cmake || echo "$HOME/.local/state/yab-spike-cef/yabcore-v2/tools/cmake/data/bin/cmake")"
check() {
  local label="$1" root="$2" want="$3" work="$YAB_FARM_OUT/$1"
  mkdir -p "$work/source/src"
  cp -p YabCore/CMakeLists.txt "$work/source/CMakeLists.txt"
  rsync -a YabCore/src/ "$work/source/src/"
  "$CMAKE" -S "$work/source" -B "$work/build" -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 \
    -DUSE_SANDBOX=ON -DCEF_ROOT="$root" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON > "$work/cmake.log" 2>&1 \
    || { tail -40 "$work/cmake.log"; return 1; }
  python3 - "$work/build/compile_commands.json" "$label" "$want" <<'PY'
import json, re, shlex, subprocess, sys
entry = next(e for e in json.load(open(sys.argv[1])) if e['file'].endswith('/src/core.mm'))
words, out, skip = shlex.split(entry['command']), [], False
for word in words:
    if skip: skip = False; continue
    if word == '-o': skip = True; continue
    out.append(word)
# Which side of the guard these headers put the core on, then the whole file.
macros = subprocess.run(out + ['-E', '-dM'], cwd=entry['directory'], capture_output=True, text=True, errors='replace')
side = re.search(r'^#define YABCORE_PRIVATE_EXTENSIONS (\d)$', macros.stdout, re.M)
print(f'{sys.argv[2]}: YABCORE_PRIVATE_EXTENSIONS', side and side.group(1))
if not side or side.group(1) != sys.argv[3]:
    sys.stderr.write(macros.stderr[-4000:]); print(f'{sys.argv[2]}: FAIL, expected {sys.argv[3]}'); sys.exit(1)
probe = subprocess.run(out + ['-fsyntax-only'], cwd=entry['directory'], capture_output=True, text=True, errors='replace')
sys.stdout.write(probe.stdout); sys.stderr.write(probe.stderr[-20000:])
print(f'{sys.argv[2]}: core.mm syntax and types', 'PASS' if probe.returncode == 0 else 'FAIL')
sys.exit(probe.returncode)
PY
}
check with-0092 "$SHADOW" 1
check release "$SDK" 0
echo 'PASS: the core compiles with 0092 and without it'
