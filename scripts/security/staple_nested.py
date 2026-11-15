#!/usr/bin/env python3
"""Attach existing notarization tickets to embedded helper apps, inside out.

Run only after Apple's notarization accepted the complete app. This submits
nothing, signs nothing, and never changes entitlements. Frameworks, dylibs and
bare executables are not independently distributable app bundles.
"""
import argparse
from pathlib import Path
import subprocess
import time


def nested_apps(app):
    return sorted((p for p in app.rglob('*.app') if p.is_dir() and not p.is_symlink()),
                  key=lambda p: (-len(p.parts), str(p)))


def staple(app):
    for helper in nested_apps(app):
        # Apple's ticket lookup can lag behind the accepted submission, just
        # as for the outer app. Bound retries and fail packaging if it persists.
        for attempt in range(6):
            result = subprocess.run(['xcrun', 'stapler', 'staple', str(helper)], timeout=120)
            if result.returncode == 0:
                break
            if attempt == 5:
                result.check_returncode()
            time.sleep(20)
    verify(app)


def verify(app):
    for helper in nested_apps(app):
        subprocess.run(['xcrun', 'stapler', 'validate', str(helper)], check=True, timeout=120)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True, timeout=120)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    (verify if args.verify_only else staple)(args.app.resolve())
