#!/usr/bin/env python3
"""One native suite, real parent JS then frozen candidate JS, in one warm lane."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

BASE = "efb05855a13b3b9b5c4775c1011762c6377519d6"
SCRIPT = "Resources/PageScripts/extension-shims.js"
TEST = "Tests/FastTests/ExtensionRuleAtomicTests.swift"
METHOD = "oversizedReplacementIsAtomicAndPreservesEarlierPendingWork"
PHASES = ["replacement", "mixed", "priorPending"]
COMMAND = ["swift", "test", "--no-parallel", "--filter", "ExtensionRuleAtomicTests"]
child = None


def check(value, message):
    if not value:
        raise RuntimeError(message)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def inputs(root):
    files = [p for folder in ("Sources", "Resources", "Tests")
             for p in (root / folder).rglob("*") if p.is_file()]
    files += [root / p for p in ("Package.swift", "Package.resolved") if (root / p).is_file()]
    return {str(p.relative_to(root)): sha(p.read_bytes()) for p in sorted(files)}


def stop():
    global child
    if child is not None and child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    child = None


def interrupted(signum, _frame):
    stop()
    raise KeyboardInterrupt("signal " + str(signum))


def run(root, out, arm, script_sha, test_sha, world):
    global child
    env_values = {"YAB_PROBE": world + "-" + arm, "YAB_CHECK_WORLD": world + "-" + arm,
                  "YAB_RULE_ATOMIC_EXPECTED_SCRIPT_SHA": script_sha, "YAB_RULE_ATOMIC_ARM": arm}
    log = out / (arm + ".log")
    began = time.monotonic()
    lines = []
    print("RULE_ATOMIC_COMMAND " + json.dumps({"arm": arm, "argv": COMMAND}), flush=True)
    try:
        with log.open("w") as saved:
            child = subprocess.Popen(COMMAND, cwd=root, env=dict(os.environ, **env_values),
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, bufsize=1, start_new_session=True)
            for line in child.stdout:
                saved.write(line); saved.flush(); lines.append(line)
                print(line, end="", flush=True)
            rc = child.wait()
        child = None
    finally:
        stop()
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", "".join(lines))
    markers = {}
    for prefix in ("RULE_ATOMIC_SOURCE", "RULE_ATOMIC_PHASE"):
        markers[prefix] = [json.loads(line[len(prefix) + 1:]) for line in text.splitlines()
                           if line.startswith(prefix + " ")]
    sources = markers["RULE_ATOMIC_SOURCE"]
    phases = markers["RULE_ATOMIC_PHASE"]
    source_ok = (len(sources) == 1 and sources[0].get("arm") == arm and
                 sources[0].get("script_sha256") == script_sha)
    phase_ok = ([p.get("phase") for p in phases] == PHASES and
                all(p.get("arm") == arm and p.get("ready") is True and
                    p.get("semantic_pass") is (arm == "candidate") for p in phases))
    state = "passed" if arm == "candidate" else "failed"
    complete = (bool(re.search(r"Test " + METHOD + r"\(\) " + state + r" after", text)) and
                bool(re.search(r"Suite ExtensionRuleAtomicTests " + state + r" after", text)) and
                bool(re.search(r"Test run with 1 test(?: in 1 suite)? " + state + r" after", text)))
    causal = True
    for row in phases:
        mixed = row.get("phase") == "mixed"
        sets = ["base", "small"] if mixed else []
        traffic = row.get("traffic", {})
        causal = (causal and row.get("update", {}).get("ok") is True and
                  row.get("native") == sets and row.get("api", {}).get("sets") == sets and
                  traffic.get("blocked") == ("error" if mixed else "loaded") and
                  traffic.get("blocked_requests") == (0 if mixed else 1) and
                  traffic.get("control") == "loaded" and traffic.get("control_requests") == 1 and
                  (row.get("phase") != "priorPending" or row.get("valid", {}).get("ok") is True))
    semantic_lines = [i for i, line in enumerate((root / TEST).read_text().splitlines(), 1)
                      if '#expect(semanticPass, "RULE_ATOMIC_SEMANTIC_' in line]
    check(len(semantic_lines) == 1, "frozen semantic assertion location is ambiguous")
    issue_lines = [line for line in text.splitlines() if "recorded an issue" in line]
    issue_pattern = (r"Test " + METHOD + r"\(\) recorded an issue at (?:[^\n]*[/])?"
                     r"ExtensionRuleAtomicTests\.swift:" + str(semantic_lines[0]) + r":\d+: Expectation failed:")
    semantic_failures = (len(issue_lines) == 3 and text.count("Expectation failed") == 3 and
                         all(re.search(issue_pattern, line) for line in issue_lines) and
                         re.findall(r"RULE_ATOMIC_SEMANTIC_([A-Za-z0-9_]+):", text) == PHASES)
    accepted = (rc == (0 if arm == "candidate" else 1) and source_ok and phase_ok and complete and
                (arm == "candidate" or (causal and semantic_failures)))
    return {"arm": arm, "command": COMMAND, "env": env_values, "script_sha256": script_sha,
            "test_sha256": test_sha, "exit": rc, "seconds": time.monotonic() - began,
            "log": str(log), "log_sha256": sha(log.read_bytes()), "markers": markers,
            "compile_lines": [l.rstrip() for l in lines if "Compiling " in l],
            "assertion_lines": [l.rstrip() for l in lines if "recorded an issue" in l or "Expectation failed" in l],
            "source_marker_valid": source_ok, "phase_markers_valid": phase_ok,
            "baseline_causal_receipts_valid": causal, "semantic_failures_observed": semantic_failures,
            "complete": complete, "accepted": accepted}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--script-sha", required=True)
    parser.add_argument("--test-sha", required=True)
    args = parser.parse_args()
    check(os.environ.get("YAB_FARM_WORKER") == "1", "farm worker required")
    root = Path.cwd().resolve()
    check(root == Path(__file__).resolve().parents[2] and root.parent.name == "fast-lanes", "owned worker lane required")
    out = Path(os.environ["YAB_FARM_OUT"]) / "extension-rule-atomic"
    out.mkdir(exist_ok=False)
    script = root / SCRIPT
    original = script.read_bytes()
    result = {"base": args.base, "job": os.environ.get("YAB_FARM_JOB"),
              "arms": {}, "accepted": False, "errors": []}
    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    def save():
        (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    try:
        check(args.base == BASE, "unexpected parent revision")
        existing_world = os.environ.get("YAB_CHECK_WORLD")
        check(bool(existing_world), "existing farm YAB_CHECK_WORLD required")
        result["existing_check_world"] = existing_world
        check(all(re.fullmatch(r"[0-9a-f]{64}", s) for s in (args.script_sha, args.test_sha)), "full SHA256 required")
        check(sha(original) == args.script_sha and sha((root / TEST).read_bytes()) == args.test_sha, "frozen candidate/test mismatch")
        git_env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
        def git(*argv):
            return subprocess.check_output(["git", *argv], cwd=root, env=git_env)
        changed = git("diff", "--name-only", BASE, "--", "Sources", "Resources", "Package.swift", "Package.resolved").decode().splitlines()
        check(set(changed) == {SCRIPT}, "parent/candidate product diff must be only the owned JS")
        parent = git("show", BASE + ":" + SCRIPT)
        initial = inputs(root)
        result.update(worker_head=git("rev-parse", "HEAD").decode().strip(),
                      worker_tree=git("rev-parse", "HEAD^{tree}").decode().strip(),
                      parent_script_sha256=sha(parent), candidate_script_sha256=sha(original),
                      test_sha256=args.test_sha, runner_sha256=sha(Path(__file__).read_bytes()), sources=initial)
        world = re.sub(r"[^A-Za-z0-9_-]", "_", existing_world) + "-rule-atomic"
        for arm, data in (("baseline", parent), ("candidate", original)):
            if script.read_bytes() != data:
                script.write_bytes(data)
            expected = dict(initial, **{SCRIPT: sha(data)})
            check(inputs(root) == expected, "source inputs changed outside the JS overlay")
            result["arms"][arm] = run(root, out, arm, sha(data), args.test_sha, world)
            save()
            check(inputs(root) == expected, "source inputs changed during the native suite")
            check(result["arms"][arm]["accepted"], arm + " did not establish the required complete semantic result")
        result["accepted"] = True
    except BaseException as error:
        result["errors"].append(type(error).__name__ + ": " + str(error))
    finally:
        cleanup_error = None
        try:
            stop()
        except BaseException as error:
            cleanup_error = error
            result["errors"].append("cleanup " + type(error).__name__ + ": " + str(error))
        try:
            if script.read_bytes() != original:
                script.write_bytes(original)
            result["restored"] = sha(script.read_bytes()) == sha(original)
        except BaseException as error:
            cleanup_error = cleanup_error or error
            result["restored"] = False
            result["errors"].append("restore " + type(error).__name__ + ": " + str(error))
        result["accepted"] = result["accepted"] and result["restored"] and not result["errors"]
        try:
            save()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        if cleanup_error is not None:
            raise cleanup_error
    print("RULE_ATOMIC_RESULT " + json.dumps({"result": str(out / "result.json"), "accepted": result["accepted"], "errors": result["errors"]}), flush=True)
    return 0 if result["accepted"] else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, KeyError) as error:
        print("RULE_ATOMIC_BLOCKED " + str(error), flush=True)
        sys.exit(2)
