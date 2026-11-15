#!/usr/bin/env python3
"""Run collapsed-pair projection regression on the actual parent and candidate."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import uuid


TEST = "Tests/FastTests/CollapsedPairProjectionTests.swift"
SOURCES = ("Sources/Fast/AgentFolders.swift", "Sources/Fast/Side.swift")
SUITES = ("CollapsedPairProjectionTests", "FoldersTests", "SpaceFoldTests")
SUITE_FILTER = r"(?:^|[./])(?:" + "|".join(re.escape(suite) for suite in SUITES) + r")(?:[./]|$)"


def hashes(folder):
    return {path: hashlib.sha256((folder / path).read_bytes()).hexdigest()
            for path in (*SOURCES, TEST)}


def main():
    assert os.environ.get("YAB_FARM_WORKER") == "1", "run through ./farm exec"
    parser = argparse.ArgumentParser()
    parser.add_argument("base")
    parser.add_argument("--before-result", type=Path)
    parser.add_argument("--before-job")
    args = parser.parse_args()
    if args.before_result and not args.before_job:
        parser.error("--before-job identifies the original completed baseline")
    root = Path(__file__).resolve().parents[2]
    out = Path(os.environ["YAB_FARM_OUT"])
    base = subprocess.check_output(["git", "rev-parse", args.base + "^{commit}"], cwd=root, text=True).strip()
    assert subprocess.run(["git", "merge-base", "--is-ancestor", base, "HEAD"], cwd=root).returncode == 0, "baseline must be an actual ancestor"
    source_head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    candidate_hashes = hashes(root)
    world = "collapsed-pair-" + uuid.uuid4().hex[:10]
    result = {"base": base, "source_head": source_head, "candidate_sha256": candidate_hashes,
              "test_sha256": candidate_hashes[TEST], "phases": {}}
    if args.before_result:
        previous = json.loads(args.before_result.read_text())
        assert previous["base"] == base, "baseline commit must match"
        assert previous["candidate_sha256"] == candidate_hashes, "candidate or test changed since the first run"
        prior = previous["phases"]["before"]
        assert prior["ran"] and prior["unchanged_during_run"] and not prior["compile_failed"]
        assert prior["exit"] == 1 and prior["summary"] == "failed" and prior["suite_count"] == len(SUITES)
        assert prior["suites"][SUITES[0]]["finished"] == "failed"
        assert all(prior["suites"][suite]["finished"] == "passed" for suite in SUITES[1:])
        assert prior["sha256"][TEST] == candidate_hashes[TEST]
        for path in SOURCES:
            canonical = subprocess.check_output(["git", "show", base + ":" + path], cwd=root)
            assert prior["sha256"][path] == hashlib.sha256(canonical).hexdigest(), "baseline source must be the actual commit"
        result["phases"]["before"] = prior
        result["resumed_before"] = {"job": args.before_job, "receipt": str(args.before_result),
                                    "source_head": previous["source_head"],
                                    "receipt_sha256": hashlib.sha256(args.before_result.read_bytes()).hexdigest()}
        shutil.copy2(args.before_result.with_name("before.log"), out / "before.log")
        phases = [("after", root)]
    else:
        before = out / "before-tree"
        before.mkdir()
        archive = subprocess.check_output(["git", "archive", base, "Sources", "Resources", "Tests", "Package.swift"], cwd=root)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
            tree.extractall(before)
        shutil.copy2(root / TEST, before / TEST)
        phases = [("before", before), ("after", root)]

    def save():
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    save()
    for label, folder in phases:
        probe = world + "-" + label
        domain = "dev.serafim.fast.test." + probe
        for key, value in {"agents.watch": False, "agents.forget": True,
                           "tidy.titles": False, "folders.names": False, "tidy.downloads": False}.items():
            subprocess.run(["defaults", "write", domain, key, "-bool", str(value).lower()], check=True)
        # Share the ordinary test products with the native player checks.
        # Neither projection correctness nor mounted controls need optimized code.
        command = ["swift", "test", "--filter", SUITE_FILTER]
        phase_hashes = hashes(folder)
        assert phase_hashes[TEST] == result["test_sha256"], "both phases must use the same regression"
        if label == "after":
            assert phase_hashes == candidate_hashes, "candidate changed before its run"
        print("COLLAPSED_PAIR_PHASE " + label, flush=True)
        lines = []
        with (out / (label + ".log")).open("w") as log:
            with subprocess.Popen(command, cwd=folder, env=dict(os.environ, YAB_PROBE=probe, YAB_AGENTS="none"),
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1) as child:
                for line in child.stdout:
                    lines.append(line)
                    log.write(line)
                    print(line, end="", flush=True)
                code = child.wait()
        plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", "".join(lines))
        states = {suite: {"started": bool(re.search(r"Suite " + suite + r" started\.", plain)),
                          "finished": (re.findall(r"Suite " + suite + r" (passed|failed) after\b", plain) or [None])[-1]}
                  for suite in SUITES}
        summary = re.search(r"Test run with ([1-9][0-9]*) tests? in ([1-9][0-9]*) suites? (passed|failed)\b", plain)
        ran = bool(summary) and all(state["started"] and state["finished"] for state in states.values())
        unchanged = hashes(folder) == phase_hashes
        result["phases"][label] = {"exit": code, "ran": bool(ran), "suites": states,
            "test_count": int(summary[1]) if summary else None,
            "suite_count": int(summary[2]) if summary else None,
            "summary": summary[3] if summary else None,
            "sha256": phase_hashes, "unchanged_during_run": unchanged,
            "recorded_issue": "recorded an issue" in plain,
            "compile_failed": "error:" in plain and not any(state["started"] for state in states.values()),
            "test_events": [line for line in plain.splitlines()
                            if re.search(r"Test .+ (?:started\.|(?:passed|failed) after\b)", line)]}
        save()
        if not ran or not unchanged or int(summary[2]) != len(SUITES):
            return 2
    before_result, after_result = result["phases"]["before"], result["phases"]["after"]
    result["candidate_unchanged_after_pair"] = hashes(root) == candidate_hashes
    result["source_head_after"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    valid = (before_result["exit"] == 1 and before_result["summary"] == "failed"
             and before_result["suites"][SUITES[0]]["finished"] == "failed"
             and all(before_result["suites"][suite]["finished"] == "passed" for suite in SUITES[1:])
             and after_result["exit"] == 0 and after_result["summary"] == "passed"
             and all(state["finished"] == "passed" for state in after_result["suites"].values())
             and not after_result["recorded_issue"]
             and before_result["test_count"] == after_result["test_count"]
             and result["source_head_after"] == source_head
             and result["candidate_unchanged_after_pair"])
    result["valid_pair"] = valid
    save()
    print("COLLAPSED_PAIR_RESULTS " + json.dumps(result), flush=True)
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
