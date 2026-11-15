#!/usr/bin/env python3
"""Read only the crash report belonging to this isolated probe PID."""
import json
import os
from pathlib import Path
import re
import sys

pid = int(sys.argv[1])
folder = Path.home() / 'Library/Logs/DiagnosticReports'
for path in sorted(folder.glob('*.ips'), key=lambda p: p.stat().st_mtime, reverse=True)[:100]:
    raw = path.read_text(errors='replace')
    if not re.search(r'"pid"\s*:\s*' + str(pid) + r'\b', raw):
        continue
    data = json.JSONDecoder().raw_decode(raw)[1]
    report = json.loads(raw[data:])
    if report.get('pid') != pid:
        continue
    out = Path(os.environ['YAB_FARM_OUT'])
    (out / 'probe-crash.ips').write_text(raw)
    print('CRASH', path.name, report.get('procPath'), report.get('exception'))
    images = report.get('usedImages', [])
    index = report.get('faultingThread', 0)
    frames = report.get('threads', [])[index].get('frames', [])
    for frame in frames[:30]:
        image = images[frame['imageIndex']] if 'imageIndex' in frame else {}
        print(frame.get('symbol'), frame.get('symbolLocation'), frame.get('imageOffset'), image.get('path'))
    break
else:
    print('No crash report for probe PID', pid)
