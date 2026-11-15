#!/usr/bin/env python3
"""Compare committed-main chat context with the candidate in one farm test job.

Only the job's isolated snapshot is swapped. No app, model, branch or display.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


def run_tests(root, out, label, suites):
    env = dict(os.environ, YAB_PROBE="peek-chat-" + label + "-" + os.urandom(4).hex(), YAB_HISTORY="own", YAB_AGENTS="none")
    command = ["swift", "test", "--filter", suites]
    lines = []
    with (out / (label + ".log")).open("w") as log:
        process = subprocess.Popen(command, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
            lines.append(line)
        process.wait()
    return process.returncode, "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    args = parser.parse_args()
    if os.environ.get("YAB_FARM_WORKER") != "1":
        parser.error("Run through ./farm exec")
    root = Path(__file__).resolve().parents[2]
    out = Path(os.environ["YAB_FARM_OUT"]) / "peek-chat-context"
    out.mkdir(parents=True, exist_ok=False)
    test = Path("Tests/FastTests/PeekChatContextTests.swift")
    tests = (root / test).read_bytes()
    report = {"base": args.base, "test_sha256": hashlib.sha256(tests).hexdigest(),
              "scope": "Real ChatAttach, page resolution and agent prompt formatting; no model calls or reporter profile"}
    for path in ("Package.swift",):
        assert (root / path).read_bytes() == subprocess.check_output(["git", "show", args.base + ":" + path], cwd=root), path
    # Keep the same source paths and incremental cache in this frozen worker slot.
    with tempfile.TemporaryDirectory(prefix="peek-chat-context-") as scratch:
        scratch = Path(scratch)
        archive = scratch / "base.tar"
        with archive.open("wb") as output:
            subprocess.run(["git", "archive", args.base, "Sources", "Tests"], cwd=root, stdout=output, check=True)
        with tarfile.open(archive) as source:
            source.extractall(scratch / "base")
        saved = scratch / "candidate"
        saved.mkdir()
        swapped = []
        try:
            for folder in ("Sources", "Tests"):
                shutil.move(str(root / folder), saved / folder)
                swapped.append(folder)
                shutil.move(str(scratch / "base" / folder), root / folder)
            (root / test).write_bytes(tests)
            rc, log = run_tests(root, out, "before", "PeekChatContextTests")
            report["before_exit"] = rc
            report["baseline_regression_proven"] = rc == 1 and "Test run with 6 tests" in log and all(
                marker in log for marker in ("A new chat must receive the visible Peek page",
                    "A private Peek must not attach the unrelated page underneath",
                    "An empty Peek must not attach the unrelated page underneath"))
        finally:
            for folder in swapped:
                shutil.rmtree(root / folder, ignore_errors=True)
                shutil.move(str(saved / folder), root / folder)
        (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        if not report.get("baseline_regression_proven"):
            raise SystemExit("Baseline did not prove the expected context regression; inspect before.log")
    rc, log = run_tests(root, out, "after", "PeekChatContextTests|PeekChatPayloadTests|ChatAttachmentTroubleTests|LinkPeekRoutingTests")
    report["after_exit"] = rc
    report["passed"] = rc == 0 and "PeekChatPayloadTests" in log and "passed" in log
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PEEK_CHAT_CONTEXT " + json.dumps(report), flush=True)
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
