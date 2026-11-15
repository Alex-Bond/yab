#!/bin/bash
# TransportOverflowTests against BASE's client and transport: 40,000 events
# while nobody consumes. Before flow control this ends the client's
# connection, which ends the helper and every Chromium page. Passes when it
# does, for that reason.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
BASE="${1:?base commit}"
DEST="$YAB_FARM_OUT/baseline"
mkdir -p "$DEST"
git archive "$BASE" YabCore/Client | tar -x -C "$DEST"
cp YabCore/Client/Tests/YabCoreClientTests/TransportFake.swift YabCore/Client/Tests/YabCoreClientTests/TransportOverflowTests.swift \
  "$DEST/YabCore/Client/Tests/YabCoreClientTests/"
python3 - "$BASE" "$DEST" <<'PY'
from pathlib import Path
import subprocess, sys
base, out = sys.argv[1], Path(sys.argv[2])
header = subprocess.check_output(['git', 'show', base + ':YabCore/src/core.h'], text=True)
body = header[header.index('namespace yc {'):header.index('CefRefPtr<CefApp> MakeApp')]
body = body.replace('using Completion', '// using Completion')
transport = subprocess.check_output(['git', 'show', base + ':YabCore/src/transport.mm'], text=True)
transport = transport.replace('#include "core.h"', '#import <Foundation/Foundation.h>\n#include <functional>\n' + body + '}\n')
transport = transport.replace('#include "core_lifetime.h"',
    'namespace yc { static void WatchPeer(int) {} namespace original_caller { static void ConnectionDropped() {} static void ConnectionAccepted(int) {} } }')
transport = transport.replace('#include "original_caller.h"', '')
(out / 'baseline-transport.mm').write_text(transport)
PY
clang++ -std=c++20 -fobjc-arc -DBASELINE -I"$DEST" -framework Foundation -framework CoreFoundation \
  YabCore/tests/transport_fake.mm -o "$DEST/transport-fake"
set +e
YAB_TRANSPORT_FAKE="$DEST/transport-fake" swift test --package-path "$DEST/YabCore/Client" --scratch-path "$DEST/build" \
  --filter TransportOverflowTests 2>&1 | tee "$DEST/test.log"
RESULT=${PIPESTATUS[0]}
set -e
python3 - "$DEST/test.log" "$RESULT" "$BASE" <<'PY'
import json, sys
from pathlib import Path
log = Path(sys.argv[1]).read_text()
assert int(sys.argv[2]) != 0, 'BASE passed the overflow test'
assert 'YabCore client disconnected' in log, 'BASE failed for another reason'
assert 'every page ends' in log, 'the helper did not lose its client'
reason = [line for line in log.splitlines() if 'YabCore client disconnected' in line][0]
Path(sys.argv[1]).with_suffix('.json').write_text(json.dumps({'base': sys.argv[3], 'events': 40000,
    'disconnect': reason.strip(), 'scope': 'client lost: helper and every Chromium page end'}, indent=2) + '\n')
print('PASS base: the same load ends every page:', reason.strip())
PY
