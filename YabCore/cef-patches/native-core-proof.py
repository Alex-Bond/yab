#!/usr/bin/env python3
"""Run existing core contracts with read-only diagnostics, never sampling."""
from pathlib import Path
import importlib.util
import subprocess
spec = importlib.util.spec_from_file_location('owncef_core_contracts', Path('evals/chromium-core/run.py').resolve())
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def diagnose(pid, out):
    # The existing harness's old failure path samples a process. That can ask
    # for Developer Tools credentials and is prohibited by program.md.
    with (out / 'lsof.txt').open('w') as log:
        subprocess.run(['lsof', '-p', str(pid)], stdout=log, stderr=log, timeout=15)
module.diagnose = diagnose
module.main()
