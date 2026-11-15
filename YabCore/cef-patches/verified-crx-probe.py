#!/usr/bin/env python3
"""Native verified original package and mandatory Chrome warnings, before install."""
import argparse
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import threading
import time
import traceback
import zipfile
from native_rpc import NativeRPC
from host_lifetime import NativeHostLifetime

EXTENSION = 'eimadpbcbfnmbkopoojfekhnkhdbieeh'
PACKAGE_SHA = '864a7301c6841b34066c3537c12eab1c17a2f4cc8f27c5f05ece2b11b2615586'
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Native CRX owner</title><style>body{margin:0;background:#f7f3e8;color:#222;font:26px system-ui;height:100vh}</style><h1>Original verified extension</h1><input>'
        self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--app',type=Path,required=True);parser.add_argument('--crx',type=Path,required=True);parser.add_argument('--host',type=Path,required=True);parser.add_argument('--expected-sha',default=PACKAGE_SHA);args=parser.parse_args()
    out=Path(os.environ['YAB_FARM_OUT']);out.mkdir(parents=True,exist_ok=True)
    data=args.crx.read_bytes();assert hashlib.sha256(data).hexdigest()==args.expected_sha
    magic,version,size=struct.unpack_from('<4sII',data);assert magic==b'Cr24' and version==3
    original=zipfile.ZipFile(io.BytesIO(data[12+size:])).read('manifest.json')
    manifest=json.loads(original);assert manifest['version']
    report={'checks':[],'packageSHA256':hashlib.sha256(data).hexdigest(),'originalManifestSHA256':hashlib.sha256(original).hexdigest(),'sourceV1ProductEnabled':False}
    rpc=host=host_lifetime=None;server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Page)
    threading.Thread(target=server.serve_forever,daemon=True).start();site=f'http://127.0.0.1:{server.server_port}'
    def check(name,value,detail=None):
        report['checks'].append({'check':name,'passed':bool(value),'detail':detail});assert value,(name,detail)
    try:
        rpc=NativeRPC(args.app,out)
        check('native verified CRX entry advertised',rpc.hello['nativeHooks'].get('verifiedCrxInstall'),rpc.hello)
        rpc.call('profile.open',{'profile':'crx'});manage=rpc.call('extension.open',{'profile':'crx'})['tab'];rpc.ready(manage)
        owner=rpc.call('tab.create',{'profile':'crx','url':site+'/'})['tab'];rpc.ready(owner)
        host=subprocess.Popen([str(args.host),str(out)],stdout=rpc.log,stderr=rpc.log,start_new_session=True)
        host_lifetime=NativeHostLifetime(host,args.host,out)
        subprocess.run(['./stage','put',str(host.pid),'4'],capture_output=True,text=True,timeout=20)
        rpc.eventually('native foreground host',lambda: json.loads((out/'host-window.json').read_text()).get('key') if (out/'host-window.json').exists() else False)
        rpc.call('tab.focus',{'tab':owner,'focused':True})
        def rows(tab=manage):return rpc.call('extension.list',{'tab':tab})
        def installed(tab=manage):return any(r['id']==EXTENSION for r in rows(tab))
        def begin(tab=manage,profile='crx',path=args.crx,expected=EXTENSION):
            return rpc.send('extension.installCrx',{'tab':tab,'profile':profile,'extension':expected,'path':str(path.resolve())})
        def consent(mark):
            return rpc.event(lambda e:e['event']=='extension.consent' and e['params'].get('extensionId')==EXTENSION,mark,90)
        def inspect(question):
            check('manifest comes from original verified package', question.get('verifiedCrx') is True and
                question.get('manifest','').encode()==original and question.get('manifestSHA256','').lower()==report['originalManifestSHA256'],question)
            check('native Chrome permission warnings retained',question.get('operation')=='install' and
                question.get('warnings') and all(isinstance(w.get('text'),str) and w['text'] for w in question['warnings']),question['warnings'])
            check('native profile and original version retained',question.get('profile')=='crx' and question.get('version')==manifest['version'],question)
        def answer(question,accept,profile=None):
            return rpc.call('extension.consent.reply',{'profile':profile or question['profile'],'extension':question['extensionId'],
                'request':question['request'],'accept':accept},allow_error=bool(profile))
        mark=len(rpc.events);operation=begin();question=consent(mark);inspect(question)
        check('not registered before native consent',not installed() and operation not in rpc.responses)
        foreign=answer(question,True,'another-profile');check('foreign profile cannot accept', 'error' in foreign,foreign)
        answer(question,False);cancelled=rpc.result(operation)
        check('Cancel reports native cancellation without registration',cancelled.get('status')=='cancelled' and not installed(),cancelled)
        duplicate=rpc.call('extension.consent.reply',{'profile':'crx','extension':EXTENSION,'request':question['request'],'accept':True},allow_error=True)
        check('retired consent cannot be replayed','error' in duplicate,duplicate)
        for label,path,expected in [('wrong-id',args.crx,'a'*32),('tampered',out/'tampered.crx',EXTENSION)]:
            if label=='tampered':
                damaged=bytearray(data);damaged[12+size+128]^=1;path.write_bytes(damaged)
            mark=len(rpc.events);operation=begin(path=path,expected=expected);result=rpc.result(operation,timeout=120)
            questions=[e for e in rpc.events[mark:] if e['event']=='extension.consent']
            check(label+' is rejected before consent/registration',result.get('status')=='error' and not questions and not installed(),result)
        mark=len(rpc.events);operation=begin();question=consent(mark);inspect(question)
        check('second verified operation still awaits consent',not installed() and operation not in rpc.responses)
        answer(question,True);accepted=rpc.result(operation,timeout=120)
        check('Allow reports actual native installed ID/version',accepted.get('status')=='installed' and accepted.get('extensionId')==EXTENSION and accepted.get('version')==manifest['version'],accepted)
        rpc.eventually('native registry contains extension',installed)
        effect=rpc.eventually('verified code affects original owner',lambda: (lambda v:v if v['count']>0 else None)(
            rpc.js(owner,"return {count:document.querySelectorAll('style.darkreader').length,color:getComputedStyle(document.body).backgroundColor}")))
        report['effect']=effect
        mark=len(rpc.events);rpc.call('extension.action.open',{'tab':owner,'extension':EXTENSION,'anchor':{'x':100,'y':100,'width':24,'height':24}})
        popup=rpc.event(lambda e:e['event']=='popup.layer' and e['params'].get('tab')==owner and e['params'].get('extensionId')==EXTENSION and
            e['params'].get('state')=='frame' and e['params'].get('pixelWidth',0)>100 and e['params'].get('pixelHeight',0)>100,mark)
        # The first full-size frame can still be Dark Reader's about: placeholder.
        # Pump the original widget until its geometry settles after async data.
        opened_at=time.monotonic();last_geometry=None;changed_at=opened_at
        def settled_popup():
            nonlocal last_geometry,changed_at,popup
            rpc.call('tab.state',{'tab':owner})
            latest=next((e['params'] for e in reversed(rpc.events) if e['event']=='popup.layer' and e['params'].get('token')==popup['token'] and e['params'].get('state')=='frame'),popup)
            geometry=(latest.get('pixelWidth'),latest.get('pixelHeight'))
            if geometry!=last_geometry:last_geometry=geometry;changed_at=time.monotonic()
            popup=latest
            return latest if time.monotonic()-opened_at>=2 and time.monotonic()-changed_at>=.5 else None
        popup=rpc.eventually('settled original Dark Reader widget',settled_popup,15)
        context=popup['contextId'];check('real extension popup has unsigned native context',0<context<=0xffffffff and int(context)==context,popup)
        scale=popup['scale'];state={'token':'verified-dark-reader','contextId':context,'width':popup['pixelWidth']/scale,'height':popup['pixelHeight']/scale}
        pending=out/'host-state.pending';pending.write_text(json.dumps(state));pending.replace(out/'host-state.json')
        rpc.eventually('real Dark Reader SCK',lambda:(out/'verified-dark-reader.json').exists(),35)
        capture=json.loads((out/'verified-dark-reader.capture.json').read_text());pixels=json.loads((out/'verified-dark-reader.json').read_text())
        check('original Dark Reader popup is really on screen',capture['on_screen'] is True and pixels['key'] and pixels['active'] and pixels['own']=='ScreenCaptureKit',capture)
        report['popup']=popup;rpc.call('popup.close',{'tab':owner,'token':popup['token']})
        rpc.call('profile.open',{'profile':'retired'});retired=rpc.call('extension.open',{'profile':'retired'})['tab'];rpc.ready(retired)
        mark=len(rpc.events);operation=begin(tab=retired,profile='retired');question=consent(mark)
        rpc.call('tab.navigate',{'tab':retired,'url':site+'/replacement'});result=rpc.result(operation)
        check('owner document replacement cancels verified operation',result.get('status')=='cancelled',result)
        withdrawn=rpc.event(lambda e:e['event']=='extension.consent.withdrawn' and e['params'].get('request')==question['request'],mark)
        check('retired native question is withdrawn',bool(withdrawn))
        verify=rpc.call('extension.open',{'profile':'retired'})['tab'];rpc.ready(verify)
        check('retired owner cannot install after cancellation',not installed(verify))
        operation=begin(tab=verify,profile='retired');rpc.shutdown()
        check('pending native installer exits cleanly at shutdown',rpc.process.returncode==0,rpc.process.returncode)
        report['passed']=True
    except BaseException as error:
        report['error']=repr(error)+' '+traceback.format_exc()[-2200:];raise
    finally:
        host_ok = host_lifetime.close() if host_lifetime else host is None
        report['naturalHostExit'] = host_ok
        report['passed'] = report.get('passed') is True and host_ok
        try:
            if rpc:report['events']=rpc.events;rpc.close()
        finally:
            server.shutdown();server.server_close();(out/'crx-proof.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report.get('passed'): raise RuntimeError('Native assertions or original host cleanup failed')
if __name__=='__main__':main()
