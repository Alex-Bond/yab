#!/usr/bin/env python3
"""Compile changed objects in an isolated result folder with GN's exact flags.

This is an early diagnostic while Ninja prepares its full dependency graph.
It does not replace the source framework build or generate missing headers.
"""
import os
from pathlib import Path
import shlex
import subprocess

src = Path(os.environ.get('YAB_CHROMIUM_SRC', str(Path.home() / 'chromium/src')))
build = src / 'out/Release_GN_arm64'
out = Path(os.environ['YAB_FARM_OUT'])
ninja = Path.home() / 'chromium/depot_tools/ninja'
targets = [
    'obj/ui/accelerated_widget_mac/accelerated_widget_mac/accelerated_widget_mac.o',
    'obj/cef/libcef_static/window_view.o',
]
for target in targets:
    text = subprocess.check_output([str(ninja), '-C', str(build), '-t', 'commands', '-s', target], text=True)
    commands = text.strip().splitlines()
    if len(commands) != 1:
        raise SystemExit('OwnCEF: expected exactly one direct compiler command')
    command = shlex.split(commands[0])
    for flag in ('-o', '-MF'):
        index = command.index(flag) + 1
        command[index] = str(out / (Path(target).name + ('.d' if flag == '-MF' else '')))
    (out / (Path(target).name + '.command.txt')).write_text(shlex.join(command) + '\n')
    print('Compiling isolated diagnostic:', target, flush=True)
    result = subprocess.run(command, cwd=build)
    if result.returncode:
        raise SystemExit(result.returncode)
