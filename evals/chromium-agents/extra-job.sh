#!/bin/bash
# Reuse the sealed app from our completed parity job; never rebuild/re-sign it.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "${1:-}" == --app ]]; then
    APP="${2:?exact signed app required}"
else
    SOURCE_JOB="${1:?completed signed job required}"
    [[ "$SOURCE_JOB" =~ ^[0-9a-f]{16}$ ]]
    ./farm fetch "$SOURCE_JOB" "$YAB_FARM_OUT/retained"
    APP="$YAB_FARM_OUT/retained/$YAB_TASK_NAME.app"
fi
[[ -d "$APP" ]]
export YAB_TEST_CEF_APP="$APP" YAB_ENGINE=chromium
trap 'python3 evals/chromium-scripts/ownership.py "$YAB_FARM_OUT"' EXIT
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
app=Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
for binary in (app, app/'Contents/MacOS/YabCore'):
    subprocess.run(['codesign','--verify','--deep','--strict',str(binary)],check=True,timeout=60)
    sig=subprocess.run(['codesign','-d','--verbose=4',str(binary)],capture_output=True,text=True,check=True,timeout=60).stderr
    assert 'TeamIdentifier=25UG4QYN9F' in sig
PY
python3 -u - "$APP" <<'PY'
import json, os
from pathlib import Path
import signal, subprocess, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
app=Path(sys.argv[1]); out=Path(os.environ['YAB_FARM_OUT']); results={}
scripts=[('spaces',['python3','-u','evals/chromium-agents/direct.py','--suite','spaces'],240),
         ('gates',['python3','-u','evals/chromium-agents/direct.py','--suite','gates'],240),
         *[(name,['python3','-u','evals/chromium-agents/extra.py','--suite',name],budget)
           for name,budget in [('native',240),('keys',360),('many-keys',480),('ask-motion',300),('swarm',1200)]],
         ('golden-secrets',['python3','-u','evals/golden/chromium_agent_secrets.py'],1500),
         ('golden-user-tabs',['python3','-u','evals/golden/agent_user_tabs.py'],1200),
         ('golden-cli-launch',['bash','evals/golden/agent_cli_launch.sh'],600)]
for name,command,budget in scripts:
    folder=out/name; folder.mkdir()
    if name.startswith('golden-') and name != 'golden-secrets':
        env=dict(os.environ,YAB_FARM_OUT=str(folder))
    else:
        env=dict(os.environ)
        command += ['--app',str(app),'--out',str(folder)]
    with (folder/'eval.log').open('w') as log:
        child=None
        try:
            child=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            rc=child.wait(timeout=budget)
            results[name]={'passed':rc==0,'exit':rc}
        except subprocess.TimeoutExpired:
            results[name]={'passed':False,'timeout':budget}
        finally:
            results.setdefault(name, {'passed':False,'interrupted':True})
            if child is not None:
                # This fresh process group belongs only to this suite. A
                # raw AppKit test host can outlive its CLI parent or retain
                # stdout; reap the whole owned group at a finite deadline.
                def members():
                    rows=subprocess.check_output(['ps','-axo','pid=,pgid=,stat=,comm='],text=True).splitlines()
                    return [line.strip() for line in rows if len(parts:=line.split(None,3))==4
                            and parts[1]==str(child.pid) and not parts[2].startswith('Z')]
                left=members()
                if left:
                    if results.get(name,{}).get('passed'):
                        time.sleep(1)
                        left=members()
                    if left:
                        results[name].update(passed=False,owned_children_left=left)
                    try: os.killpg(child.pid,signal.SIGTERM)
                    except ProcessLookupError: pass
                    time.sleep(.5)
                    try: os.killpg(child.pid,signal.SIGKILL)
                    except ProcessLookupError: pass
                child.wait(timeout=5)
            subprocess.run(['python3','evals/chromium-scripts/ownership.py',str(folder)],check=True,timeout=60)
    print(name,json.dumps(results[name]),flush=True)
    print((folder/'eval.log').read_text(errors='replace')[-3500:],flush=True)
    (out/'extra-summary.json').write_text(json.dumps(results,indent=2)+'\n')
if not all(row['passed'] for row in results.values()): raise SystemExit(1)
PY
