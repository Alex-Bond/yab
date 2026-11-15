#!/usr/bin/env python3
"""One farm-only native visibility check using the existing AppKit host."""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import uuid


SUITES = {"PlayerVisibilityTests": 2, "SettingsAnchorTests": 3,
          "PlayerScrubTests": 10, "PlayerPromotionTests": 3}
FILTER = r"(^|\.)(PlayerVisibilityTests|SettingsAnchorTests|PlayerScrubTests|PlayerPromotionTests)(/|\.|$)"
NEW_METHODS = {"visibilityDefaultsOnAndTheRealSettingPersistsBothChoices()",
               "hidingRemovesTheMountedSlotAndRoomWithoutChangingThePlayer()"}


def main():
    if os.environ.get("YAB_FARM_WORKER") != "1" or platform.system() != "Darwin":
        raise RuntimeError("Run once through ./farm exec --low --display.")
    out = Path(os.environ["YAB_FARM_OUT"]) / "player-visibility-547"
    out.mkdir(exist_ok=False)
    read = lambda argv: subprocess.check_output(argv, text=True).strip()
    runtime = {"macOS": read(["sw_vers", "-productVersion"]),
               "swift": read(["xcrun", "swift", "--version"]),
               "sdk": read(["xcrun", "--show-sdk-version"]),
               "machine": platform.machine()}
    (out / "runtime.json").write_text(json.dumps(runtime, indent=2) + "\n")
    version = lambda value: tuple(int(n) for n in value.split(".")[:2])
    if version(runtime["macOS"]) < (15, 4) or version(runtime["sdk"]) < (15, 4):
        raise RuntimeError("macOS and its SDK must support the existing 15.4 AppKit host.")
    swift = re.search(r"Swift version (\d+)", runtime["swift"])
    if swift is None or int(swift[1]) < 6:
        raise RuntimeError("Swift 6 or later is required.")
    commit = read(["git", "rev-parse", "HEAD"])
    env = dict(os.environ)
    env["YAB_CHECK_WORLD"] = "player547-" + uuid.uuid4().hex
    sources = {}
    for suite in SUITES:
        path = Path("Tests/FastTests") / (suite + ".swift")
        sources[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = {"snapshot": commit, "world": env["YAB_CHECK_WORLD"],
                "filter": FILTER, "expectedSuites": SUITES, "sources": sources,
                "scope": "Mounted native controls, measured room, persistence, unchanged controlled playback model",
                "limits": "No audible media or provider playback acceptance"}
    (out / "source.json").write_text(json.dumps(manifest, indent=2) + "\n")
    rc = subprocess.run([sys.executable, "scripts/runs/appkit_gate_tests.py",
                         "--filter", FILTER, "--commit", commit, "--no-parallel"], env=env).returncode
    if rc:
        return rc
    gate = out.parent / "appkit-gate-tests"
    result = json.loads((gate / "result.json").read_text())
    rows = [json.loads(line) for line in (gate / "swift-testing.events.jsonl").read_text().splitlines()]
    methods = {row["payload"]["id"]: row["payload"] for row in rows
               if row.get("kind") == "test" and row.get("payload", {}).get("kind") == "function"}
    events = [row["payload"] for row in rows if row.get("kind") == "event"]
    counts = lambda kind: Counter(event["testID"] for event in events
                                  if event.get("kind") == kind and event.get("testID") in methods)
    suites = Counter(identifier.split(".", 1)[1].split("/", 1)[0] for identifier in methods)
    new = {method["name"] for identifier, method in methods.items()
           if identifier.startswith("FastTests.PlayerVisibilityTests/")}
    log = (gate / "swift-testing.log").read_text()
    passed = (result.get("complete") is True and result.get("sourceCommit") == commit
              and result.get("selectedSwiftMethods") == 18 and suites == Counter(SUITES)
              and new == NEW_METHODS and counts("testStarted") == Counter({key: 1 for key in methods})
              and counts("testEnded") == counts("testStarted")
              and not any(event.get("kind") in {"testSkipped", "issueRecorded"} for event in events)
              and "APPKIT_GATE_RUNNER running=true" in log
              and "APPKIT_GATE_COMPLETE rc=0" in log)
    receipt = {"passed": passed, "sourceCommit": commit, "actualMethods": len(methods),
               "actualSuites": dict(suites), "newMethods": sorted(new),
               "gateResult": result, "limits": manifest["limits"]}
    (out / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PLAYER_VISIBILITY_547_RESULT " + json.dumps(receipt), flush=True)
    return 0 if passed else 86


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"PLAYER_VISIBILITY_547_INCOMPLETE {type(error).__name__}: {error}", flush=True)
        sys.exit(86)
