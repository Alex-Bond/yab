#!/usr/bin/env python3
"""Exercise the actual ScrollLatch enum with deterministic event boundaries.

Foundation/CoreGraphics source contract. No AppKit, real windows, input events,
Guardian, browser, or performance claims. Compilation runs through the farm.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def enum_source(source):
    matches = list(re.finditer(r'^@MainActor\nenum ScrollLatch \{', source, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError('Expected exactly one actual @MainActor ScrollLatch enum')
    start = matches[0].start()
    depth, index, mode, comments = 1, matches[0].end(), 'code', 0
    while index < len(source):
        pair, character = source[index:index + 2], source[index]
        if mode == 'line':
            if character == '\n':
                mode = 'code'
        elif mode == 'block':
            if pair == '/*':
                comments += 1
                index += 1
            elif pair == '*/':
                comments -= 1
                index += 1
                if not comments:
                    mode = 'code'
        elif mode == 'string':
            if character == '\\':
                index += 1
            elif character == '"':
                mode = 'code'
        elif pair == '//':
            mode = 'line'
            index += 1
        elif pair == '/*':
            mode, comments = 'block', 1
            index += 1
        elif character == '"':
            mode = 'string'
        elif character == '{':
            depth += 1
        elif character == '}':
            depth -= 1
            if not depth:
                return source[start:index + 1]
        index += 1
    raise ValueError('Unclosed ScrollLatch enum')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tab', type=Path, default=ROOT / 'Sources/Fast/Tab.swift')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--label', default='candidate')
    args = parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER') != '1':
        parser.error('Run through ./farm; this contract compiles Swift')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = args.tab.read_text()
    actual = enum_source(source)
    template = (HERE / 'boundary.swift').read_text()
    marker = '// ACTUAL_SCROLL_LATCH_ENUM'
    if template.count(marker) != 1:
        raise ValueError('The enum insertion marker must occur exactly once')
    generated = out / 'scroll-latch-contract.swift'
    generated.write_text(template.replace(marker, actual))
    binary = out / 'scroll-latch-contract'
    report = {
        'label': args.label,
        'scope': 'Actual entire ScrollLatch enum with headless Foundation/CoreGraphics event/view boundaries',
        'unverified': ['native AppKit delivery and clipping geometry', 'reporter profile', 'Guardian', 'general page or trackpad lag'],
        'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'enum_sha256': hashlib.sha256(actual.encode()).hexdigest(),
        'extraction': 'Complete enum inserted byte for byte; private route exercised through its actual monitor callback',
    }
    compilation = subprocess.run(['swiftc', '-parse-as-library', str(generated), '-o', str(binary)],
                                 capture_output=True, text=True, timeout=90)
    (out / 'compile.log').write_text(compilation.stdout + compilation.stderr)
    print(compilation.stdout, end='', flush=True)
    print(compilation.stderr, end='', file=sys.stderr, flush=True)
    report['compile_exit_code'] = compilation.returncode
    if compilation.returncode:
        report['passed'] = False
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        return 2
    execution = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    (out / 'run.log').write_text(execution.stdout + execution.stderr)
    print(execution.stdout, end='', flush=True)
    print(execution.stderr, end='', file=sys.stderr, flush=True)
    report['run_exit_code'] = execution.returncode
    records = [line for line in execution.stdout.splitlines() if line.startswith('{')]
    if records:
        report.update(json.loads(records[-1]))
    else:
        report.update(passed=False, error='No contract result was produced')
    report['passed'] = bool(report.get('passed')) and execution.returncode == 0
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
