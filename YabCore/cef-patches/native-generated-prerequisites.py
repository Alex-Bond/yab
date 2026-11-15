#!/usr/bin/env python3
"""Generate exact normal/shared/Blink changed-Mojo bindings, no native C++ proof."""
from pathlib import Path
import hashlib,json,os,subprocess
HERE=Path(__file__).resolve().parent
# Source79's six changed inputs. New sources/variants need explicit review.
VARIANTS={
 'media/mojo/mojom/audio_stream_factory.mojom':True,
 'pdf/mojom/pdf.mojom':False,
 'services/network/public/mojom/url_request.mojom':True,
 'services/video_capture/public/mojom/video_source.mojom':False,
 'third_party/blink/public/mojom/frame/frame.mojom':True,
 'third_party/blink/public/mojom/mediastream/media_stream.mojom':True,
}
def candidate_targets(sources):
 result=set()
 for source in sources:
  prefix='gen/'+source
  result.update([prefix+'.h',prefix+'-shared.h',prefix+'-shared-internal.h',prefix+'-blink.h'])
 return result
def selected_targets(sources,declared):
 if len(sources)!=len(set(sources)) or set(sources)!=set(VARIANTS):
  raise RuntimeError('Changed Mojo input set drift; review exact variants')
 expected=set()
 for source,blink in VARIANTS.items():
  prefix='gen/'+source;expected.update([prefix+'.h',prefix+'-shared.h',prefix+'-shared-internal.h'])
  if blink:expected.add(prefix+'-blink.h')
 found=set(declared)&candidate_targets(sources)
 if found!=expected:
  raise RuntimeError('Configured Mojo outputs drift: missing='+repr(sorted(expected-found))+' unexpected='+repr(sorted(found-expected)))
 return expected

def main():
 if os.environ.get('YAB_OWNCEF_LOCKED')!='1':raise RuntimeError('source lock required')
 if os.getpriority(os.PRIO_PROCESS,0)<10:raise RuntimeError('source nice10 required')
 jobs=int(os.environ.get('YAB_OWNCEF_JOBS','4'));load=float(os.environ.get('YAB_OWNCEF_LOAD','6'))
 if not (1<=jobs<=4 and 0<load<=6):raise RuntimeError('original compiler/resource limits required')
 if not os.environ.get('YAB_FARM_OUT'):raise RuntimeError('farm output required')
 src=Path(os.environ.get('YAB_CHROMIUM_SRC',str(Path.home()/'chromium/src'))).resolve();build=src/'out/Release_GN_arm64'
 inputs=json.loads((HERE/'native-candidate-inputs.json').read_text());sources=inputs['mojomSources']
 sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
 before={name:sha(src/name) for name in sources}
 targets=set();found=set();code=None;error=None
 report={'scope':'exact configured normal/shared/Blink generation only; no C++/runtime acceptance','sources':sources,'sourceHashes':before,'jobs':jobs,'load':load,'nativeCompileAccepted':False}
 try:
  # Pin required input set before querying metadata or dispatching a generator.
  if len(sources)!=len(set(sources)) or set(sources)!=set(VARIANTS):raise RuntimeError('changed input set drift')
  candidates=candidate_targets(sources)
  query=subprocess.Popen(['ninja','-C',str(build),'-t','targets','all'],stdout=subprocess.PIPE,text=True)
  for line in query.stdout:
   name=line.split(': ',1)[0]
   if name in candidates:found.add(name)
  if query.wait()!=0:raise RuntimeError('configured Ninja output inventory failed')
  targets=selected_targets(sources,found)
  report['targets']=sorted(targets);report['configuredCandidateOutputs']=sorted(found)
  report['generatedBefore']={name:sha(build/name) if (build/name).is_file() else None for name in targets}
  print('Generate exact current candidate bindings:22 outputs (6 normal,12 shared,4 Blink)',flush=True)
  code=subprocess.run(['ninja','-C',str(build),'-k','0','-j',str(jobs),'-l',str(load),*sorted(targets)]).returncode
  report['generatedAfter']={name:sha(build/name) if (build/name).is_file() else None for name in targets}
  if code!=0:raise RuntimeError('declared Mojo generation failed')
  if any(value is None for value in report['generatedAfter'].values()):raise RuntimeError('declared generated output absent after Ninja success')
 except Exception as failure:error={'type':type(failure).__name__,'message':str(failure)}
 after={name:sha(src/name) for name in sources};report.update({'exit':code,'sourceHashesAfter':after,'sourcesUnchanged':before==after,'error':error})
 (Path(os.environ['YAB_FARM_OUT'])/'native-generated-prerequisites.json').write_text(json.dumps(report,indent=2)+'\n')
 if before!=after:raise RuntimeError('native Mojo source changed during generation')
 if error:raise RuntimeError(error['message'])
 return 0
if __name__=='__main__':raise SystemExit(main())
