#!/usr/bin/env python3
"""Verify this fix on committed main without unrelated dirty-worktree changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

from check import run_tests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--before-job", required=True)
    args = parser.parse_args()
    if os.environ.get("YAB_FARM_WORKER") != "1":
        parser.error("Run through ./farm exec")
    root = Path(__file__).resolve().parents[2]
    out = Path(os.environ["YAB_FARM_OUT"]) / "peek-chat-context-isolated"
    out.mkdir(parents=True, exist_ok=False)
    patch = Path(__file__).with_name("change.patch")
    tests = {name: (root / "Tests/FastTests" / name).read_bytes()
             for name in ("PeekChatContextTests.swift", "PeekChatPayloadTests.swift")}
    assert (root / "Package.swift").read_bytes() == subprocess.check_output(["git", "show", args.base + ":Package.swift"], cwd=root)
    report = {"base": args.base, "before_proof_job": args.before_job,
              "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
              "test_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in tests.items()},
              "scope": "Committed main plus the context fix only; actual production prompt code; no model calls"}
    with tempfile.TemporaryDirectory(prefix="peek-chat-isolated-") as scratch:
        scratch = Path(scratch)
        archive = scratch / "base.tar"
        with archive.open("wb") as output:
            subprocess.run(["git", "archive", args.base, "Sources", "Tests"], cwd=root, stdout=output, check=True)
        with tarfile.open(archive) as source:
            source.extractall(scratch / "base")
        saved = scratch / "original"
        saved.mkdir()
        swapped = []
        try:
            for folder in ("Sources", "Tests"):
                shutil.move(str(root / folder), saved / folder)
                swapped.append(folder)
                shutil.move(str(scratch / "base" / folder), root / folder)
            subprocess.run(["git", "apply", "--check", str(patch)], cwd=root, check=True)
            subprocess.run(["git", "apply", str(patch)], cwd=root, check=True)
            for name, data in tests.items():
                (root / "Tests/FastTests" / name).write_bytes(data)
            report["product_sha256"] = {path: hashlib.sha256((root / path).read_bytes()).hexdigest()
                for path in subprocess.check_output(["git", "apply", "--numstat", str(patch)], cwd=root, text=True).splitlines()
                for path in [path.split("\t", 2)[2]]}
            rc, log = run_tests(root, out, "candidate", "PeekChatContextTests|PeekChatPayloadTests|ChatAttachmentTroubleTests|LinkPeekRoutingTests")
            report["exit"] = rc
            report["passed"] = rc == 0 and re.search(r"Test run with 19 tests(?: in \d+ suites)? passed", log) is not None
        finally:
            for folder in swapped:
                shutil.rmtree(root / folder, ignore_errors=True)
                shutil.move(str(saved / folder), root / folder)
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PEEK_CHAT_ISOLATED " + json.dumps(report), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
