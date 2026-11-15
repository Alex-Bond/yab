#!/usr/bin/env python3
"""An rsync remote shell using the coordinator's existing peer aliases."""
import argparse
import os
import shlex


def command(config, peer, arguments):
    if peer not in {'main', 'm4', 'adhd', 'renderer-2', 'm2', 'm2pro'}:
        raise ValueError('Unknown artifact peer')
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20',
           '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3',
           '-o', 'ControlPath=none']
    # rsync supplied quoting for the source shell. Keep those literal quotes
    # through the coordinator shell, before the peer's SSH command uses them.
    inner = [*ssh, '-F', '.local/state/yab-farm/ssh_config', peer, *arguments]
    return [*ssh, '-F', config, 'm4', shlex.join(inner)]


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', required=True)
    p.add_argument('peer')
    p.add_argument('arguments', nargs=argparse.REMAINDER)
    a = p.parse_args()
    argv = command(a.config, a.peer, a.arguments)
    os.execvp(argv[0], argv)
