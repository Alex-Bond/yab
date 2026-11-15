#!/usr/bin/env python3
"""Accepted native chooser frame/document, single-use reply and retirement."""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import traceback
from native_rpc import NativeRPC
from host_lifetime import NativeHostLifetime

PORT=0
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        child=self.path.startswith(('/child','/same'))
        body='''<!doctype html><title>Native file owner</title><style>body{margin:0;background:#17813f;color:white;font:20px system-ui}input{display:block;margin:18px}iframe{width:85%;height:220px;border:0}</style><h1>Native upload document</h1><input id="single" type="file" accept="application/pdf"><input id="multi" type="file" multiple><input id="folder" type="file" webkitdirectory><div id="status">No native selection</div><script>for(const input of document.querySelectorAll('input'))input.onchange=()=>{document.getElementById('status').textContent=Array.from(input.files).map(f=>f.name).join(',');document.body.style.background='#2166dc'};window.lastClick=null;document.addEventListener('click',e=>window.lastClick={target:e.target.id,trusted:e.isTrusted,active:navigator.userActivation.isActive},true);window.cancels=0;document.addEventListener('cancel',()=>window.cancels++,true)</script>'''
        if not child:body+=f'<iframe id="cross" src="http://localhost:{PORT}/child"></iframe><iframe id="same" src="/same"></iframe>'
        data=body.encode();self.send_response(200);self.send_header('Content-Type','text/html');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def log_message(self,*args):pass

def main():
    global PORT
    parser=argparse.ArgumentParser();parser.add_argument('--app',type=Path,required=True);parser.add_argument('--host',type=Path,required=True);args=parser.parse_args()
    out=Path(os.environ['YAB_FARM_OUT']);out.mkdir(parents=True,exist_ok=True);report={'checks':[],'productionSourceV1':True}
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Page);PORT=server.server_port;site=f'http://127.0.0.1:{PORT}'
    threading.Thread(target=server.serve_forever,daemon=True).start();rpc=host=host_lifetime=None
    def check(name,value,detail=None):
        report['checks'].append({'check':name,'passed':bool(value),'detail':detail});assert value,(name,detail)
    try:
        rpc=NativeRPC(args.app,out,extra_args=('--site-per-process','--enable-logging=stderr','--log-level=0','--yab-trace-file-origin'));rpc.call('profile.open',{'profile':'files'})
        owner=rpc.call('tab.create',{'profile':'files','url':site+'/'})['tab'];rpc.ready(owner)
        # Finish the unrelated profile/window setup before establishing the
        # foreground host, keeping this check about chooser ownership.
        rpc.call('profile.open',{'profile':'foreign'})
        foreign=rpc.call('tab.create',{'profile':'foreign','url':site+'/foreign'})['tab'];rpc.ready(foreign)
        host=subprocess.Popen([str(args.host),str(out)],stdout=rpc.log,stderr=rpc.log,start_new_session=True)
        host_lifetime=NativeHostLifetime(host,args.host,out)
        subprocess.run(['./stage','put',str(host.pid),'4'],capture_output=True,text=True,timeout=20)
        rpc.eventually('foreground file host',lambda: json.loads((out/'host-window.json').read_text()).get('key') if (out/'host-window.json').exists() else False)
        rpc.call('tab.focus',{'tab':owner,'focused':True})
        def contexts():return [c for c in rpc.contexts(owner) if c['default']]
        def mainframe():return rpc.eventually('main context',lambda:next((c for c in contexts() if c['main'] and c.get('nativeDocument')),None))
        def childframe(path):return rpc.eventually('iframe context',lambda:next((c for c in contexts() if not c['main'] and c['url'].endswith(path) and c.get('nativeDocument')),None))
        main=mainframe();cross=childframe('/child');same=childframe('/same')
        check('cross-origin iframe is an actual OOPIF',cross['session'] and cross['frameId']!=main['frameId'],cross)
        check('same-process iframe keeps an independent context',not same['session'] and same['frameId']!=main['frameId'],same)
        # A renderer attempt without native acceptance cannot mint a request.
        mark=len(rpc.events);rpc.js(owner,"document.querySelector('#single').click();return true",frame=main)
        deadline=time.monotonic()+.8
        while time.monotonic()<deadline:
            try:rpc.pump(min(.1,deadline-time.monotonic()))
            except (socket.timeout,TimeoutError):pass
        check('no-gesture attempt has no accepted native callback',not [e for e in rpc.events[mark:] if e['event']=='file.open'])
        one=out/'one.pdf';one.write_bytes(b'%PDF-1.4\nNative chooser fixture\n%%EOF\n')
        two=out/'two.txt';two.write_text('Second native selected file\n')
        handoff=out/'handoff.pdf';handoff.write_bytes(one.read_bytes())
        def receipt(opened,context):
            source=rpc.call('file.nativeSource',{'tab':owner,'request':opened['request']})
            native=source['native'];auth=source['authenticated']
            check('native callback maps to this exact frame and document',auth and native['request']==opened['request'] and
                native['document']==context['nativeDocument']==auth['nativeDocument'] and native['frameId']==context['frameId']==auth['frame']['frameId'] and
                auth['frame']['token']==context['token'] and native['main'] is context['main'] and auth['frame']['main'] is context['main'],source)
            check('production v1 carries the exact authenticated native chooser',
                source['productionSourceV1'] is True and isinstance(opened.get('source'),dict) and
                opened['source']==auth and auth.get('version')==1 and
                auth.get('request')==opened['request'] and
                auth.get('session')==context['session'] and
                auth['frame']['token']==context['token'] and
                auth['nativeDocument']==context['nativeDocument'],source)
            report.setdefault('requests',[]).append({'open':opened,'receipt':source})
            return source
        def native_click(context,selector):
            # Fixture geometry chooses the input target; ownership still comes
            # exclusively from the accepted native callback and document map.
            if not context['main']:
                parent_selector='#cross' if '/child' in context['url'] else '#same'
                rpc.js(owner,"document.querySelector(arg).scrollIntoView({block:'center'});return true",parent_selector,frame=main)
            rpc.js(owner,"document.querySelector(arg).scrollIntoView({block:'center'});return true",selector,frame=context)
            point=rpc.js(owner,"const r=document.querySelector(arg).getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2}",selector,frame=context)
            if not context['main']:
                parent=rpc.js(owner,"const r=document.querySelector(arg).getBoundingClientRect();return {x:r.left,y:r.top}",parent_selector,frame=main)
                point={'x':point['x']+parent['x'],'y':point['y']+parent['y']}
            for kind in ['mouseMove','mouseDown','mouseUp']:
                rpc.call('input.send',{'tab':owner,'kind':kind,'x':point['x'],'y':point['y'],'clickCount':1})
            return point
        def open_pick(context,selector='#single'):
            mark=len(rpc.events);point=native_click(context,selector)
            try:opened=rpc.event(lambda e:e['event']=='file.open' and e['params'].get('tab')==owner,mark)
            except Exception:
                report['failedAdmission']={'context':context,'selector':selector,'point':point,
                    'dom':rpc.js(owner,"return {click:window.lastClick,cancels:window.cancels,active:navigator.userActivation.isActive,beenActive:navigator.userActivation.hasBeenActive,focus:document.hasFocus(),visibility:document.visibilityState}",frame=context),
                    'nativeState':rpc.call('tab.state',{'tab':owner})}
                raise
            receipt(opened,context)
            return opened,mark
        def reply(opened,paths,tab=owner,allow_error=False):
            return rpc.call('file.reply',{'tab':tab,'request':opened['request'],'paths':[str(p) for p in paths]},allow_error=allow_error)
        def capture(name):
            def current_layer():
                rpc.call('tab.state',{'tab':owner})
                return next((e['params'] for e in reversed(rpc.events) if e['event']=='layer.changed' and e['params'].get('tab')==owner and e['params'].get('contextId')),None)
            layer=rpc.eventually('native page layer',current_layer)
            state={'token':name,'contextId':layer['contextId'],'width':layer.get('width',800),'height':layer.get('height',600)}
            pending=out/'host-state.pending';pending.write_text(json.dumps(state));pending.replace(out/'host-state.json')
            rpc.eventually('native file capture',lambda:(out/(name+'.json')).exists(),35)
            pixels=json.loads((out/(name+'.json')).read_text())
            if pixels.get('own')!='ScreenCaptureKit':raise RuntimeError('Native window capture failed: '+str(pixels.get('own')))
            receipt=json.loads((out/(name+'.capture.json')).read_text())
            report.setdefault('captureState',[]).append({'capture':name,'pixels':pixels,
                'host':json.loads((out/'host-window.json').read_text()),'native':rpc.call('tab.state',{'tab':owner})})
            check('file owner is captured from native compositor',receipt['on_screen'] is True and pixels['own']=='ScreenCaptureKit' and pixels['key'] and pixels['active'],receipt)
        capture('files-before')
        opened,mark=open_pick(main)
        bad=reply(opened,[one],tab=foreign,allow_error=True);check('foreign tab cannot answer native chooser','error' in bad,bad)
        for paths in [[one,two],['relative.pdf'],[str(one)+'\x00suffix']]:
            bad=reply(opened,paths,allow_error=True);check('invalid paths/count do not consume native chooser','error' in bad,bad)
        reply(opened,[one]);chosen=rpc.eventually('original input receives file',lambda:rpc.js(owner,"return Array.from(document.querySelector('#single').files).map(f=>f.name)",frame=main))
        check('original native single-file callback delivered the actual file',chosen==['one.pdf'],chosen)
        bad=reply(opened,[two],allow_error=True);check('selected callback cannot be replayed','error' in bad,bad)
        # The real Files field/panel takes first responder from the page.
        # Keyboard focus is not tab selection or native document ownership.
        opened,mark=open_pick(main)
        rpc.call('tab.focus',{'tab':owner,'focused':False})
        pending=rpc.call('file.nativeSource',{'tab':owner,'request':opened['request']},allow_error=True)
        check('picker UI keyboard focus preserves the exact native chooser',
            'error' not in pending and pending['native']['request']==opened['request'] and
            pending['authenticated']['nativeDocument']==main['nativeDocument'],pending)
        reply(opened,[handoff])
        names=rpc.eventually('picker keyboard handoff receives file',lambda:(lambda value:value if value==['handoff.pdf'] else None)(
            rpc.js(owner,"return Array.from(document.querySelector('#single').files).map(f=>f.name)",frame=main)))
        check('picker reply reaches original input without page keyboard focus',names==['handoff.pdf'],names)
        rpc.call('tab.focus',{'tab':owner,'focused':True})
        capture('files-selected')
        opened,mark=open_pick(main,'#multi');check('native multiple mode retained',opened['multiple'] is True,opened);reply(opened,[one,two])
        names=rpc.eventually('original multiple input',lambda:rpc.js(owner,"return Array.from(document.querySelector('#multi').files).map(f=>f.name)",frame=main))
        check('native multiple callback preserves files',names==['one.pdf','two.txt'],names)
        opened,mark=open_pick(main,'#folder');check('native directory mode retained',opened['directories'] is True and opened['multiple'] is False,opened);reply(opened,[])
        # Alternate real main, same-process and OOPIF frame owners.
        for context in [cross,main,same,cross,main]:
            opened,mark=open_pick(context);reply(opened,[])
        first,mark=open_pick(main)
        # Blink queues a second same-page chooser until the first completes.
        # WebContents rejects a concurrent OOPIF chooser before native admission.
        # Preserve both checks: a renderer attempt is not an accepted callback.
        attempts=len(rpc.events)
        cancels=rpc.js(owner,'return window.cancels',frame=cross)
        native_click(cross,'#single')
        rpc.eventually('concurrent OOPIF chooser rejected by Chrome',lambda:rpc.js(owner,'return window.cancels',frame=cross)>cancels)
        native_click(main,'#multi')
        deadline=time.monotonic()+.5
        while time.monotonic()<deadline:
            try:rpc.pump(min(.1,deadline-time.monotonic()))
            except (socket.timeout,TimeoutError):pass
        check('rapid renderer attempts mint no extra native callback',not [e for e in rpc.events[attempts:] if e['event']=='file.open'])
        check('rejected and queued attempts retain the first native owner',rpc.call('file.nativeSource',{'tab':owner,'request':first['request']})['native']['request']==first['request'])
        reply(first,[])
        second=rpc.event(lambda e:e['event']=='file.open' and e['params'].get('tab')==owner and e['params'].get('request')!=first['request'],attempts)
        receipt(second,main)
        check('queued accepted request gets a distinct native identity',first['request']!=second['request'] and second['multiple'] is True)
        bad=reply(first,[one],allow_error=True);check('retired reply cannot reach the next chooser','error' in bad,bad)
        check('stale reply leaves the newer native callback intact',rpc.call('file.nativeSource',{'tab':owner,'request':second['request']})['native']['request']==second['request'])
        reply(second,[])
        opened,mark=open_pick(cross);old_document=cross['nativeDocument']
        rpc.js(owner,'location.href=arg;return true',f'http://localhost:{PORT}/child-next',frame=cross)
        rpc.event(lambda e:e['event']=='file.closed' and e['params'].get('request')==opened['request'],mark)
        cross=childframe('/child-next');check('same native frame navigation gets a new document',cross['frameId']==report['requests'][-1]['receipt']['native']['frameId'] and cross['nativeDocument']!=old_document,cross)
        bad=reply(opened,[one],allow_error=True);check('old document cannot answer after replacement','error' in bad,bad)
        opened,mark=open_pick(cross);rpc.js(owner,"document.querySelector('#cross').remove();return true",frame=main)
        rpc.event(lambda e:e['event']=='file.closed' and e['params'].get('request')==opened['request'],mark)
        bad=reply(opened,[one],allow_error=True);check('removed OOPIF cannot receive a file','error' in bad,bad)
        opened,mark=open_pick(main);rpc.call('tab.visible',{'tab':owner,'visible':False})
        rpc.event(lambda e:e['event']=='file.closed' and e['params'].get('request')==opened['request'],mark)
        bad=reply(opened,[one],allow_error=True);check('tab switch retires the exact chooser','error' in bad,bad)
        rpc.call('tab.visible',{'tab':owner,'visible':True});rpc.call('tab.focus',{'tab':owner,'focused':True})
        opened,mark=open_pick(main);rpc.call('page.crashForTesting',{'tab':owner})
        rpc.event(lambda e:e['event']=='file.closed' and e['params'].get('request')==opened['request'],mark)
        bad=reply(opened,[one],allow_error=True);check('renderer loss refuses late file delivery','error' in bad,bad)
        closed=[e['params']['request'] for e in rpc.events if e['event']=='file.closed']
        check('each withdrawn native request retires exactly once',len(closed)==len(set(closed)),closed)
        rpc.shutdown();check('native file helper exits cleanly',rpc.process.returncode==0,rpc.process.returncode);report['passed']=True
    except BaseException as error:report['error']=repr(error)+' '+traceback.format_exc()[-2400:];raise
    finally:
        host_ok = host_lifetime.close() if host_lifetime else host is None
        report['naturalHostExit'] = host_ok
        report['passed'] = report.get('passed') is True and host_ok
        try:
            if rpc:report['events']=rpc.events;rpc.close()
        finally:
            server.shutdown();server.server_close();(out/'files-proof.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report.get('passed'): raise RuntimeError('Native assertions or original host cleanup failed')
if __name__=='__main__':main()
