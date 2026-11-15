#!/usr/bin/env python3
"""Read only the owned baseline receipts, bounded log tail and current resources."""
import datetime
import json
from pathlib import Path
import re
import shutil
import time


def main():
    root = Path('/data/yab-chromium-baseline')
    receipt = json.loads((root / 'resume-build-receipt.json').read_text())
    log = root / 'logs/build-j6.log'
    with log.open('rb') as stream:
        stream.seek(max(0, log.stat().st_size - 16384))
        tail = stream.read().decode(errors='replace')
    actions = re.findall(r'\[(\d+)/(\d+)\]', tail)
    memory = dict(re.findall(r'^(\w+):\s+(\d+)\s+kB', Path('/proc/meminfo').read_text(), re.M))
    result = {
        'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'attempt': 'j6-incremental', 'completed': receipt['completed'],
        'exitCode': receipt['exitCode'], 'actions': actions[-1] if actions else None,
        'freeBytes': shutil.disk_usage(root).free,
        'memAvailableKiB': int(memory['MemAvailable']),
        'load': Path('/proc/loadavg').read_text().strip(),
        'logAgeSeconds': round(time.time() - log.stat().st_mtime, 1),
        'syntaxHeaderExists': (root / 'checkout/src/out/YabDesktopArm64/gen/content/public/common/'
                              'extra_mojo_js_features.mojom.h').is_file(),
        'tail': tail[-250:],
    }
    if receipt.get('artifacts'):
        result['artifacts'] = receipt['artifacts']
    print(json.dumps(result))


if __name__ == '__main__':
    main()
