#!/usr/bin/env python3
"""Verify that an isolated probe left no process from its exact app bundle."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unicodedata

app = str(Path(sys.argv[1]).resolve()) + '/Contents/'
rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
matching = []
for row in rows:
    fields = row.strip().split(None, 1)
    if len(fields) != 2:
        continue
    command = unicodedata.normalize('NFC', fields[1])
    if command.startswith('/') and str(Path(command).resolve()).startswith(app):
        matching.append({'pid': int(fields[0]), 'executable': command})
report = {'app': app, 'remaining': matching, 'allStopped': not matching}
(Path(os.environ['YAB_FARM_OUT']) / 'cleanup.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
raise SystemExit(bool(matching))
