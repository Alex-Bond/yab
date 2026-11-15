#!/usr/bin/env python3
"""Run the actual Tab.loadAndVerify body against deterministic boundaries.

This is a source extraction contract, not native WebKit or reporter-profile
acceptance. Run through ./farm; no app, display, account, or network is used.
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


def method_source(source):
    matches = list(re.finditer(r'^    private func loadAndVerify\(', source, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError('Expected exactly one actual private Tab.loadAndVerify method')
    start = matches[0].start()
    opening = source.find('{', matches[0].end())
    if opening < 0:
        raise ValueError('loadAndVerify body not found')
    depth, index, mode, comments = 1, opening + 1, 'code', 0
    while index < len(source):
        pair = source[index:index + 2]
        character = source[index]
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
    raise ValueError('Unclosed loadAndVerify method')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tab', type=Path, default=ROOT / 'Sources/Fast/Tab.swift')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--label', default='candidate')
    args = parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER') != '1':
        parser.error('Run this contract through ./farm; it compiles Swift')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = args.tab.read_text()
    actual_method = method_source(source)
    template = (HERE / 'boundary.swift').read_text()
    marker = '    // ACTUAL_TAB_LOAD_AND_VERIFY_METHOD'
    if template.count(marker) != 1:
        raise ValueError('Fixture method insertion marker must occur exactly once')
    generated = out / 'recovery-contract.swift'
    generated.write_text(template.replace(marker, actual_method))
    binary = out / 'recovery-contract'
    report = {
        'label': args.label,
        'scope': 'Actual Tab.loadAndVerify method, deterministic scheduler and PageView boundaries',
        'unverified': ['native WebKit behavior', 'reporter profile and websites', 'visible acceptance'],
        'tab_source': str(args.tab.resolve()),
        'tab_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'extracted_method_sha256': hashlib.sha256(actual_method.encode()).hexdigest(),
        'extraction': 'The complete method is inserted byte for byte; no rewritten implementation',
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
    lines = [line for line in execution.stdout.splitlines() if line.startswith('{')]
    if lines:
        report.update(json.loads(lines[-1]))
    else:
        report['passed'] = False
        report['error'] = 'Contract did not produce its JSON result'
    report['passed'] = bool(report.get('passed')) and execution.returncode == 0
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
