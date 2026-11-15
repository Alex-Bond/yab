"""Launch the compiled signed CEF app in an isolated test bundle container."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_app import OwnedApp, _same, launch as launch_probe


def launch_exact(app, env, out, extra_env_names=(), arguments=()):
    """Exact compiled input, in a fresh Developer ID-signed test container.

    YAB_PROBE isolates files, but a dev bundle still selects its bundle's
    default WK jar. The existing probe launcher gives each world its own
    bundle, checks the copied executable before signing, and preserves CEF's
    separately signed helper/frameworks. No user cookie jar is borrowed.
    """
    if os.environ.get('YAB_FARM_WORKER') != '1' or os.environ.get('WHERE') not in ('adhd', 'm4', 'renderer-2'):
        raise RuntimeError('Signed CEF runtime checks require a permitted farm worker')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    engine = env.get('YAB_ENGINE')
    if engine and '-YabPageEngine' not in arguments:
        arguments = (*arguments, '-YabPageEngine', engine)
    proc = launch_probe(app, dict(env, YAB_HEADLESS='0'), out,
                           extra_env_names=extra_env_names,
                           task_name=os.environ.get('YAB_TASK_NAME') or info['CFBundleDisplayName'],
                           arguments=arguments)
    actual = proc.binary.parents[2]
    actual_info = plistlib.loads((actual / 'Contents/Info.plist').read_bytes())
    assert actual_info['CFBundleIdentifier'].startswith('dev.serafim.yab.probe.gui.')
    for code in (actual, actual / 'Contents/MacOS/YabCore'):
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(code)], check=True, timeout=60)
        sig = subprocess.run(['codesign', '-d', '--verbose=4', str(code)], capture_output=True,
                             text=True, check=True, timeout=60).stderr
        assert 'TeamIdentifier=25UG4QYN9F' in sig, sig
    (out / 'launch-mode.json').write_text(json.dumps({'interactive': True, 'headless': False,
        'input_app': str(app), 'actual_app': str(actual), 'name': actual_info['CFBundleDisplayName'],
        'binary': str(proc.binary), 'bundle_id': actual_info['CFBundleIdentifier'],
        'isolated_bundle_container': True, 'signing': 'Developer ID 25UG4QYN9F',
        'engine': engine, 'arguments': list(arguments)}, indent=2))
    return proc


def require_window(ask):
    """A successful offscreen agent read is not ordinary-window UI proof."""
    until = time.monotonic() + 30
    last = None
    while time.monotonic() < until:
        try:
            ask(do='front')
            last = ask(do='window')
            if len(last.get('frame', [])) == 4: return last
        except Exception as error: last = repr(error)
        time.sleep(.15)
    raise RuntimeError('The isolated app has no ordinary browser window: ' + str(last))


def require_page_window(ask, tab=None):
    until = time.monotonic() + 20
    last = None
    while time.monotonic() < until:
        normal = require_window(ask)
        last = ask(do='chromium', **({'id': tab} if tab else {}))
        if last['window'] == normal['number'] and last['context'] > 0: return last
        time.sleep(.15)
    raise RuntimeError('Chromium page did not join the ordinary browser window: ' + str(last))
