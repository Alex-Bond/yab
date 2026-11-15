#!/usr/bin/env python3
"""Custom Space arrows through the app router in an isolated profile.

Uses owned queued NSEvents, never OS-global input. No reporter-profile claim.
"""
import argparse, json, os, subprocess, sys, threading, time, uuid
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'evals'))
from probe_app import launch
from yab_socket import asker, socket_path
class Page(BaseHTTPRequestHandler):
 def do_GET(self):
  body=("<title>Space keys</title><body style='font:24px -apple-system;padding:50px'><h1>"+self.path+"</h1><textarea id='editor'>test words</textarea><p>This page prevents every key.</p><script>addEventListener('keydown', e=>{e.preventDefault();window.lastKey=e.code})</script>").encode()
  self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(body)
 def log_message(self,*args):pass
parser=argparse.ArgumentParser();parser.add_argument('--app',required=True);parser.add_argument('--edges-only',action='store_true');parser.add_argument('--source',default=os.environ.get('YAB_SOURCE_REV'));args=parser.parse_args()
out=Path(os.environ['YAB_FARM_OUT'])/('space-keys-931-edges' if args.edges_only else 'space-keys-931');out.mkdir(parents=True,exist_ok=True)
report={'base':args.source,'app':str(Path(args.app).resolve()),'scope':'Owned in-process queued NSEvent CmdOptionLeft/Right through the app router; controlled fresh profile without reporter extensions, IME or personal App Shortcuts','checks':[],'shots':[]}
world='keys931-'+uuid.uuid4().hex[:10];domain='dev.serafim.fast.test.'+world
for key in ('bench','welcomed'):subprocess.run(['defaults','write',domain,key,'-bool','true'],check=True)
subprocess.run(['defaults','write',domain,'dev.offer','-bool','false'],check=True)
subprocess.run(['defaults','write',domain,'shortcuts','-dict','previousSpace','⌥⌘←','nextSpace','⌥⌘→'],check=True)
server=ThreadingHTTPServer(('127.0.0.1',0),Page);threading.Thread(target=server.serve_forever,daemon=True).start()
process=launch(args.app,dict(os.environ,YAB_PROBE=world,YAB_HISTORY='own'),out,task_name=os.environ['YAB_TASK_NAME'])
raw=asker(socket_path(world));names=['Alpha931','Beta931','Gamma931'];tabs={}
def ask(verb,**fields):
 r=raw(dict(do=verb,**fields))
 if 'error' in r:raise RuntimeError(f'{verb}: {r}')
 return r
def check(name,ok,**data):
 report['checks'].append(dict(name=name,passed=bool(ok),**data));print(('PASS ' if ok else 'FAIL ')+name,flush=True)
def key(code,mods):
 ask('front')
 # Address an owned fixture tab only and retain the actual current first responder.
 name={123:'left',124:'right',37:'l'}[code]
 return ask('chord',id=key.tab,keys=('cmd+opt+' if code in (123,124) else 'cmd+')+name,
            focus=False,post=True,code=code,wait=.3)
key.tab=None
def current():return next(s['name'] for s in ask('spaces')['spaces'] if s['current'])
def shot(name):
 p=out/(name+'.png');ask('winshot',path=str(p),scale=1);report['shots'].append(str(p.name))
try:
 ask('ui',welcome=False,sidebar=True,shut=False,bar=False)
 ask('space',on=True)
 for name in names:
  ask('space',new=name)
  tab=ask('open',url=f'http://127.0.0.1:{server.server_port}/{name}',plain=True,space=name)
  tabs[name]=tab['id'];ask('wait',id=tab['id']);ask('select',id=tab['id']);time.sleep(.35)
 order=ask('spaces')['order'];report['order']=order
 menu=ask('app-menu',menu='Spaces');report['menu']=menu
 check('custom arrow bindings appear in the actual menu',any(i.get('title')=='Next Space' and i.get('key')=='⌥⌘\uf703' for i in menu['items']) and any(i.get('title')=='Previous Space' and i.get('key')=='⌥⌘\uf702' for i in menu['items']),items=menu['items'])
 for mode in (() if args.edges_only else ('page','textarea','omnibox','hidden-sidebar','tabs-on-top')):
  for direction,code in ((-1,123),(1,124)):
   for n in range(4):
    ask('space',to='Beta931');time.sleep(.3);ask('select',id=tabs['Beta931']);time.sleep(.3);key.tab=tabs['Beta931']
    ask('ui',sidebar=mode!='tabs-on-top',shut=mode=='hidden-sidebar',bar=mode=='tabs-on-top')
    ask('page-keys',keys=[],wait=.1)
    if mode=='textarea':ask('eval',id=tabs['Beta931'],js="document.getElementById('editor').focus();document.activeElement.id")
    if mode=='omnibox':key(37,'command')
    if n==0 and direction==-1:shot(mode+'-before')
    focus_before=ask('page-keys',keys=[],focus=False,wait=.01);before=current();key(code,'command,option');after=current()
    expected=order[(order.index(before)+direction)%len(order)]
    check(f'{mode} {direction:+} attempt {n+1}',after==expected,before=before,after=after,expected=expected,focus_before=focus_before)
    if n==0 and direction==1:shot(mode+'-after')
 ask('space',to='Beta931');time.sleep(.3);ask('select',id=tabs['Beta931']);time.sleep(.3);key.tab=tabs['Beta931'];ask('page-keys',keys=[],wait=.1)
 for n,code in enumerate([] if args.edges_only else [124,123]*6):
  key.tab=tabs[current()];ask('select',id=key.tab);time.sleep(.3)
  focus_before=ask('page-keys',keys=[],focus=False,wait=.01);before=current();key(code,'command,option');after=current();delta=1 if code==124 else -1
  expected=order[(order.index(before)+delta)%len(order)]
  check(f'alternating app key {n+1}',after==expected,before=before,after=after,expected=expected,focus_before=focus_before)
 # Current browser behavior wraps at both ends. Exercise the real router.
 for edge,code,target in ((order[0],123,order[-1]),(order[-1],124,order[0])):
  for n in range(4):
   ask('space',to=edge);time.sleep(.3)
   tab=ask('open',url=f'http://127.0.0.1:{server.server_port}/edge-{code}-{n}',plain=True,space=edge)
   ask('wait',id=tab['id']);ask('select',id=tab['id']);time.sleep(.3);key.tab=tab['id']
   ask('page-keys',keys=[],wait=.1)
   before=current();key(code,'command,option');after=current()
   check(f'wrap {code} attempt {n+1}',after==target,before=before,after=after,expected=target)
 report['passed']=all(c['passed'] for c in report['checks'])
finally:
 (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 process.terminate();process.wait();server.shutdown()
 subprocess.run(['defaults','delete',domain],capture_output=True)
print('RESULT '+json.dumps({'passed':report.get('passed'), 'checks':len(report['checks'])}),flush=True)
raise SystemExit(0 if report.get('passed') else 1)
