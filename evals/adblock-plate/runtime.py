"""Farm-only dependency setup for the address plate golden check."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

if os.environ.get("YAB_FARM_WORKER") != "1":
    raise SystemExit("Run through the shared display farm with --needs pointer")
out = Path(os.environ["YAB_FARM_OUT"])
prepared = None
check = '''import ctypes, importlib.util, json, sys
cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cg.CGPreflightPostEventAccess.restype = ctypes.c_bool
print(json.dumps({"executable": sys.executable, "events": bool(cg.CGPreflightPostEventAccess()),
 "modules": all(importlib.util.find_spec(n) is not None for n in ("AppKit", "Quartz", "ApplicationServices"))}))
'''
observed = []
for python in dict.fromkeys((sys.executable, "/usr/bin/python3", "/usr/local/bin/python3")):
    if not Path(python).exists():
        continue
    result = subprocess.run([python, "-c", check], capture_output=True, text=True)
    if result.returncode == 0:
        observed.append(json.loads(result.stdout))
(out / "runtime.json").write_text(json.dumps(observed, indent=2) + "\n")
print(json.dumps(observed), flush=True)
qualified = [p for p in observed if p["events"]]
if not qualified:
    raise SystemExit("BLOCKED: no observed Python is permitted to post pointer events")
chosen = next((p for p in qualified if p["modules"]), qualified[0])
python = chosen["executable"]
env = dict(os.environ)
if not chosen["modules"]:
    target = out / "pyobjc"
    subprocess.run([python, "-m", "pip", "install", "--target", str(target),
                    "pyobjc-framework-Cocoa", "pyobjc-framework-Quartz",
                    "pyobjc-framework-ApplicationServices"], check=True)
    prepared = target
    packages = subprocess.check_output([python, "-m", "pip", "list", "--path", str(target), "--format=json"], text=True)
    (out / "runtime-packages.json").write_text(packages)
    env["PYTHONPATH"] = str(target) + os.pathsep + env.get("PYTHONPATH", "")
    verified = subprocess.run([python, "-c", check], env=env, check=True, capture_output=True, text=True)
    receipt = json.loads(verified.stdout)
    (out / "runtime-prepared.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if not receipt["events"] or not receipt["modules"]:
        raise SystemExit("BLOCKED: prepared runtime did not pass module and posting preflight")
try:
    result = subprocess.run([python, "-u", "evals/golden/adblock_plate.py", *sys.argv[1:]], env=env)
finally:
    if prepared:
        shutil.rmtree(prepared)
raise SystemExit(result.returncode)
