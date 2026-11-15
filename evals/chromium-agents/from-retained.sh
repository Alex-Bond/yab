#!/bin/bash
# Copy the sealed artifact from its retained source, then verify and replay.
# The source Mac only serves files; all execution remains on the farm worker.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?Run through the farm}"
SOURCE_HOST="${1:?Retained artifact host required}"
SOURCE_APP="${2:?Retained artifact path required}"
shift 2
APP="$YAB_FARM_OUT/retained/$YAB_TASK_NAME.app"
python3 - "$SOURCE_HOST" "$SOURCE_APP" "$APP" <<'PY'
from pathlib import Path
import os
import shlex
import subprocess
import sys

host, source, target = sys.argv[1:]
if host not in ('main', 'adhd', 'renderer-2', 'm4'):
    raise SystemExit('Expected a farm artifact source')
if not source.startswith('/') or not source.endswith('.app'):
    raise SystemExit('Expected an absolute retained app path')
Path(target).mkdir(parents=True)
if host == os.environ.get('WHERE'):
    # Automatic scheduling may choose the artifact's own Mac. Copy locally;
    # a worker need not trust an SSH connection back to itself.
    subprocess.run(['ditto', source, target], check=True, timeout=600)
else:
    subprocess.run(['rsync', '-a', '-e', 'ssh -o BatchMode=yes -o ConnectTimeout=10',
                    host + ':' + shlex.quote(source + '/'), target + '/'], check=True, timeout=600)
PY
bash evals/chromium-agents/replay.sh "$APP" "$@"
