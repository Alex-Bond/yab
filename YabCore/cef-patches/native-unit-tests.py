#!/usr/bin/env python3
"""Run an exact already-produced native utility binary. Never builds or opens UI."""
import argparse,hashlib,json,os,re,resource,shutil,signal,struct,subprocess,sys,time
from pathlib import Path
from xml.etree import ElementTree as ET
HERE=Path(__file__).resolve().parent
class Rejected(RuntimeError):pass
def require(value,message):
 if not value:raise Rejected(message)
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def expected_manifest(path):
 m=json.loads(path.read_text());tests=m['tests']
 require(m['schema']==1 and m['target']=='//cef:libcef_static_unittests','unknown target manifest')
 require(len(tests)==m['testCount']==35 and len(set(tests))==35,'expected exactly35 unique registered native tests')
 require(all(re.fullmatch(r'[A-Za-z_]\w*\.[A-Za-z_]\w*',t) for t in tests),'invalid test name')
 require(sorted({t.split('.')[0] for t in tests})==m['suites'],'suite set drift')
 for rel,digest in m['sourceInputs'].items():
  require(not Path(rel).is_absolute() and '..' not in Path(rel).parts and re.fullmatch('[0-9a-f]{64}',digest),'invalid source binding')
 return m

def parse_discovery(text,expected):
 suite=None;found=[]
 for raw in text.splitlines():
  line=raw.split('#',1)[0].rstrip()
  if re.fullmatch(r'[A-Za-z_]\w*\.',line):suite=line[:-1]
  elif re.fullmatch(r'  [A-Za-z_]\w*',line):
   require(suite is not None,'test without suite');found.append(suite+'.'+line.strip())
 require(found,'zero native tests discovered')
 require(len(found)==len(set(found)),'duplicate native test discovery')
 require(set(found)==set(expected),'native discovery mismatch: missing='+repr(sorted(set(expected)-set(found)))+' extra='+repr(sorted(set(found)-set(expected))))
 return found

def parse_xml(path,expected):
 require(path.is_file() and 0<path.stat().st_size<=16*1024*1024,'missing/empty/oversized native XML')
 root=ET.parse(path).getroot();require(root.tag=='testsuites','unexpected XML root')
 require(root.get('tests')==str(len(expected)),'XML count mismatch')
 for key in ['failures','disabled','errors']:require(root.get(key)=='0','XML '+key+' is nonzero/missing')
 require(not root.findall('.//failure') and not root.findall('.//error') and not root.findall('.//skipped'),'native XML has failure/error/skip')
 rows=[]
 for case in root.findall('.//testcase'):
  name=case.get('classname','')+'.'+case.get('name','')
  require(case.get('status')=='run' and case.get('result')=='completed','test not executed/completed: '+name)
  rows.append({'name':name,'status':case.get('status'),'result':case.get('result'),'seconds':case.get('time')})
 names=[r['name'] for r in rows]
 require(len(names)==len(set(names))==len(expected) and set(names)==set(expected),'XML missing/duplicate/extra native tests')
 return rows

def macho_arm64_executable(path):
 require(path.is_file() and os.access(path,os.X_OK) and path.name=='libcef_static_unittests','wrong/missing non-executable native target')
 with path.open('rb') as f:header=f.read(16)
 require(len(header)==16,'short executable')
 magic,cpu,subtype,kind=struct.unpack('<IIII',header)
 require(magic==0xfeedfacf and cpu==0x0100000c and kind==2,'expected exact thin arm64 Mach-O executable')

def child_output_bound():
 resource.setrlimit(resource.RLIMIT_FSIZE,(64*1024*1024,64*1024*1024))
def captured_run(argv,cwd,env,log,timeout):
 record={'argv':argv,'cwd':str(cwd),'timeoutSeconds':timeout,'exitCode':None,'timedOut':False}
 start=time.monotonic()
 with log.open('wb') as output:
  process=subprocess.Popen(argv,cwd=cwd,env=env,stdout=output,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True,preexec_fn=child_output_bound)
  try:record['exitCode']=process.wait(timeout=timeout)
  except subprocess.TimeoutExpired:
   record['timedOut']=True
   try:os.killpg(process.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   try:process.wait(timeout=5)
   except subprocess.TimeoutExpired:
    try:os.killpg(process.pid,signal.SIGKILL)
    except ProcessLookupError:pass
    process.wait()
   record['exitCode']=process.returncode
 record['elapsedSeconds']=time.monotonic()-start
 return record

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,default=Path(os.environ.get('YAB_CHROMIUM_SRC',str(Path.home()/'chromium/src'))));p.add_argument('--binary',type=Path);p.add_argument('--expected-binary-sha256');p.add_argument('--output',type=Path);a=p.parse_args()
 farm=os.environ.get('YAB_FARM_OUT');require(farm,'run native tests through the existing farm job')
 source=a.source.resolve();binary=(a.binary or source/'out/Release_GN_arm64/libcef_static_unittests').resolve();out=(a.output or Path(farm)/'native-utility-tests').resolve()
 require(out.is_relative_to(Path(farm).resolve()) and out!=Path(farm).resolve(),'output must be a fresh child of this farm artifact slot')
 require(not out.exists(),'refuse overwriting native test proof');out.mkdir(parents=True)
 report={'scope':'native production utility tests only, not full CEF/SDK/browser acceptance','accepted':False,'nativeTestsExecuted':False,'binary':str(binary),'source':str(source),'target':'//cef:libcef_static_unittests','stages':{},'sdkAccepted':False,'guiOpened':False,'compilerInvoked':False,'nativeExecutionAttempted':False}
 error=None;before=None;icu=None;icu_before=None;inputs_before={};manifest_path=HERE/'native-unit-expectations.json'
 try:
  manifest=expected_manifest(manifest_path);expected=manifest['tests'];report['expectationsSha256']=sha(manifest_path);report['expectedTests']=expected
  for rel,digest in manifest['sourceInputs'].items():require((source/rel).is_file() and sha(source/rel)==digest,'source input mismatch: '+rel)
  inputs_before={rel:sha(source/rel) for rel in manifest['sourceInputs']};report['sourceInputs']=inputs_before
  macho_arm64_executable(binary);before=sha(binary);report['binarySha256Before']=before
  if a.expected_binary_sha256:require(re.fullmatch('[0-9a-f]{64}',a.expected_binary_sha256) and before==a.expected_binary_sha256,'retained binary hash mismatch')
  else:require(os.environ.get('YAB_OWNCEF_LOCKED')=='1' and binary==source/'out/Release_GN_arm64/libcef_static_unittests','retained execution requires explicit exact binary SHA256')
  # Runtime ICU data is adjacent to the exact binary. Keep a rerunnable pair.
  icu=binary.with_name('icudtl.dat');require(icu.is_file(),'missing original adjacent ICU data')
  icu_before=sha(icu);report['icuSha256']=icu_before
  retained=out/'retained';retained.mkdir();shutil.copy2(binary,retained/binary.name);shutil.copy2(icu,retained/icu.name)
  require(sha(retained/binary.name)==before and sha(retained/icu.name)==report['icuSha256'],'retained runtime copy mismatch')
  for rel in inputs_before:
   dest=retained/'source-inputs'/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source/rel,dest)
  shutil.copy2(manifest_path,retained/'native-unit-expectations.json');shutil.copy2(Path(__file__),retained/'native-unit-tests.py')
  report['retainedBinary']=str(retained/binary.name)
  env={k:v for k,v in os.environ.items() if not k.startswith(('GTEST_','TEST_LAUNCHER_'))}
  temporary=out/'tmp';temporary.mkdir();env['TMPDIR']=str(temporary)
  suites=':'.join(s+'.*' for s in manifest['suites'])
  common=[str(binary),'--single-process-tests','--test-launcher-jobs=1','--test-launcher-retry-limit=0','--gtest_repeat=1','--gtest_shuffle=0','--gtest_color=no']
  discovery=captured_run(common+['--gtest_list_tests','--gtest_filter='+suites],binary.parent,env,out/'discovery.log',30);report['stages']['discovery']=discovery
  require(discovery['exitCode']==0 and not discovery['timedOut'],'native discovery process failed/expired')
  require((out/'discovery.log').stat().st_size<=8*1024*1024,'oversized discovery log')
  report['discoveredTests']=parse_discovery((out/'discovery.log').read_text(errors='strict'),expected)
  require(sha(binary)==before,'binary changed after discovery')
  xml=out/'results.xml';run=captured_run(common+['--gtest_filter='+':'.join(expected),'--gtest_output=xml:'+str(xml)],binary.parent,env,out/'tests.log',300);report['stages']['execution']=run;report['nativeExecutionAttempted']=True
  require(run['exitCode']==0 and not run['timedOut'],'native tests failed/crashed/expired')
  report['tests']=parse_xml(xml,expected);report['nativeTestsExecuted']=True;report['passedTestCount']=len(report['tests']);report['xmlSha256']=sha(xml)
  report['accepted']=True
 except Exception as failure:
  error=str(failure);report['error']={'type':type(failure).__name__,'message':error}
 finally:
  if before is not None:
   try:after=sha(binary) if binary.is_file() else None
   except OSError as failure:after=None;report.setdefault('postcheckErrors',[]).append(str(failure))
   report['binarySha256After']=after
   if after!=before:report['accepted']=False;error=error or 'binary changed during test execution';report['binaryChanged']=True
  if icu_before is not None:
   try:icu_after=sha(icu) if icu.is_file() else None
   except OSError as failure:icu_after=None;report.setdefault('postcheckErrors',[]).append(str(failure))
   report['icuSha256After']=icu_after;report['icuInputUnchanged']=icu_after==icu_before
   if icu_after!=icu_before:report['accepted']=False;error=error or 'original ICU data changed during native tests'
  if inputs_before:
   after={}
   for rel in inputs_before:
    try:after[rel]=sha(source/rel) if (source/rel).is_file() else None
    except OSError as failure:after[rel]=None;report.setdefault('postcheckErrors',[]).append(str(failure))
   report['sourceInputsAfter']=after;report['sourceInputsUnchanged']=after==inputs_before
   if after!=inputs_before:report['accepted']=False;error=error or 'source inputs changed during execution'
  if error and 'error' not in report:report['error']={'type':'EvidenceDrift','message':error}
  (out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
 if error:print('Native utility proof refused: '+error,file=sys.stderr);return 1
 print('PASS exact35 native utility tests; '+str(out/'results.json'));return 0
if __name__=='__main__':
 try:sys.exit(main())
 except Exception as error:print('Native utility runner refused: '+str(error),file=sys.stderr);sys.exit(1)
