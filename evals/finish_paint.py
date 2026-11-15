#!/usr/bin/env python3
"""Run the recovered paint-wait A/B with the curtain raised."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', required=True)
p.add_argument('--candidate', required=True)
p.add_argument('--capture-only', action='store_true')
args = p.parse_args()
if os.environ.get('YAB_FARM_WORKER') != '1' or os.environ.get('WHERE') != 'adhd':
    p.error('run through farm on adhd')
output = Path(os.environ['APP']).resolve().parent / 'finish-paint'
output.mkdir()
helper = output / 'curtain-state'
subprocess.run(['swiftc', 'evals/usage/curtain_state.swift', '-o', str(helper)], check=True)
command = [sys.executable, 'evals/usage/stall_compare.py', '--baseline', args.baseline,
           '--candidate', args.candidate, '--out', str(output / 'comparison'),
           '--curtain-state', str(helper), '--allow-capture-gap']
if args.capture_only:command += ['--capture-only']
recorder = Path('/Users/dev/Documents/GitHub/fast-apps/farm-1620e700b76643a1/blackout-experiment/scfilm')
if recorder.is_file():command += ['--recorder', str(recorder)]
raise SystemExit(subprocess.call(command, env=dict(os.environ, PYTHONUNBUFFERED='1')))
