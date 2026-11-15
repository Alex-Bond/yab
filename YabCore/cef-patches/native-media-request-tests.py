#!/usr/bin/env python3
"""Exact11 on the SAME produced binary AFTER exact35. No compiler or GUI."""
import argparse,hashlib,importlib.util,json,os,re,shutil,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
class Rejected(RuntimeError):pass
def require(ok,message):
 if not ok:raise Rejected(message)
def digest(path):
 h=hashlib.sha256()
 with path.open('rb')as source:
  for block in iter(lambda:source.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def classification_manifest(path):
 m=json.loads(path.read_text());tests=m['tests'];require(m['schema']==1 and m['target']=='//cef:libcef_static_unittests','wrong classification target')
 require(m['testCount']==len(tests)==len(set(tests))==11,'requires exactly11 unique classification tests')
 require(m['suites']==['NativeMediaRequestClassification'],'classification suite drift')
 require(all(re.fullmatch(r'NativeMediaRequestClassification\.[A-Za-z_]\w*',t)for t in tests),'invalid classification test name')
 require(len(m['sourceInputs'])==24,'classification source pin set drift')
 for p,h in m['sourceInputs'].items():require(not Path(p).is_absolute() and '..'not in Path(p).parts and re.fullmatch('[0-9a-f]{64}',h),'invalid source pin')
 return m
def original35(prior,manifest):
 require(prior.get('accepted')is True and prior.get('nativeTestsExecuted')is True and prior.get('passedTestCount')==35,'actual prior35 proof not accepted')
 rows=prior.get('tests',[]);names=[r.get('name')for r in rows]
 require(len(names)==len(set(names))==35 and set(names)==set(manifest['tests']),'prior35 tests missing/duplicate/extra')
 require(all(r.get('status')=='run'and r.get('result')=='completed'for r in rows),'prior35 nonexecuted test')
 require(prior.get('sourceInputs')==manifest['sourceInputs'] and prior.get('sourceInputsAfter')==manifest['sourceInputs'] and prior.get('sourceInputsUnchanged')is True,'prior35 source binding mismatch')
 require(prior.get('binarySha256Before')==prior.get('binarySha256After') and re.fullmatch('[0-9a-f]{64}',prior.get('binarySha256After','')),'prior35 binary drift/missing')
 require(prior.get('icuInputUnchanged')is True and prior.get('icuSha256')==prior.get('icuSha256After') and re.fullmatch('[0-9a-f]{64}',prior.get('icuSha256After','')),'prior35 ICU drift/missing')
 require(prior.get('sdkAccepted')is False and prior.get('compilerInvoked')is False and prior.get('guiOpened')is False and prior.get('nativeExecutionAttempted')is True,'unexpected prior proof scope')
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,default=Path(os.environ.get('YAB_CHROMIUM_SRC',str(Path.home()/'chromium/src'))));p.add_argument('--binary',type=Path);p.add_argument('--expected-binary-sha256');p.add_argument('--prior-utility-receipt',type=Path);p.add_argument('--output',type=Path);a=p.parse_args()
 farm=os.environ.get('YAB_FARM_OUT');require(farm,'existing farm job required');source=a.source.resolve();binary=(a.binary or source/'out/Release_GN_arm64/libcef_static_unittests').resolve();out=(a.output or Path(farm)/'native-media-request-tests').resolve();require(out.is_relative_to(Path(farm).resolve())and out!=Path(farm).resolve(),'fresh farm child output only');require(not out.exists(),'do not overwrite proof');out.mkdir(parents=True)
 report={'scope':'production classifier/fail-deny utility tests only, not callback/browser/SDK acceptance','accepted':False,'nativeTestsExecuted':False,'nativeExecutionAttempted':False,'target':'//cef:libcef_static_unittests','binary':str(binary),'source':str(source),'stages':{},'sdkAccepted':False,'compilerInvoked':False,'guiOpened':False}
 error=None;before=None;icu=None;icu_before=None;inputs={};original_files={};base=None
 try:
  manifest_path=HERE/'native-media-request-expectations.json';m=classification_manifest(manifest_path);expected=m['tests'];report['expectationsSha256']=digest(manifest_path);report['expectedTests']=expected
  util=HERE/'native-unit-tests.py';require(digest(util)==m['utilityRunnerSHA256'],'exact unchanged35 utility runner required');unit_path=HERE/'native-unit-expectations.json';require(digest(unit_path)==m['utility35ExpectationsSHA256'],'exact current35 expectations required')
  original_files={str(f):digest(f)for f in [manifest_path,util,unit_path,Path(__file__).resolve()]}
  spec=importlib.util.spec_from_file_location('exact_native_utility35',util);base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
  unit=base.expected_manifest(unit_path);require(all(m['sourceInputs'].get(f)==h for f,h in unit['sourceInputs'].items()),'classifier must retain every original35 source pin');prior_path=(a.prior_utility_receipt or Path(farm)/'native-utility-tests/results.json').resolve();require(prior_path.is_file()and 0<prior_path.stat().st_size<=4*1024*1024,'missing/oversized prior35 receipt');prior=json.loads(prior_path.read_text());original35(prior,unit);require(prior.get('expectationsSha256')==digest(unit_path),'prior35 expectation hash mismatch');original_files[str(prior_path)]=digest(prior_path);report['runnerInputs']=original_files;report['prior35ReceiptSha256']=digest(prior_path);report['samePrior35BinaryRequired']=True
  for f,h in m['sourceInputs'].items():require((source/f).is_file()and digest(source/f)==h,'classification source mismatch: '+f)
  inputs={f:digest(source/f)for f in m['sourceInputs']};report['sourceInputs']=inputs
  base.macho_arm64_executable(binary);before=base.sha(binary);report['binarySha256Before']=before;require(before==prior['binarySha256After'],'classification binary differs from actual prior35 binary')
  if a.expected_binary_sha256:require(re.fullmatch('[0-9a-f]{64}',a.expected_binary_sha256)and before==a.expected_binary_sha256,'retained binary hash mismatch')
  else:require(os.environ.get('YAB_OWNCEF_LOCKED')=='1'and binary==source/'out/Release_GN_arm64/libcef_static_unittests','retained run requires explicit binary SHA256')
  icu=binary.with_name('icudtl.dat');require(icu.is_file(),'missing original adjacent ICU');icu_before=base.sha(icu);require(icu_before==prior['icuSha256After'],'classification ICU differs from prior35');report['icuSha256']=icu_before
  retained=out/'retained';retained.mkdir();shutil.copy2(binary,retained/binary.name);shutil.copy2(icu,retained/icu.name);require(base.sha(retained/binary.name)==before and base.sha(retained/icu.name)==icu_before,'retained runtime pair mismatch')
  for f in inputs:d=retained/'source-inputs'/f;d.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source/f,d)
  for f in [manifest_path,util,unit_path,Path(__file__).resolve()]:shutil.copy2(f,retained/f.name)
  shutil.copy2(prior_path,retained/'prior-native-utility-results.json');report['retainedBinary']=str(retained/binary.name)
  env={k:v for k,v in os.environ.items()if not k.startswith(('GTEST_','TEST_LAUNCHER_'))};temp=out/'tmp';temp.mkdir();env['TMPDIR']=str(temp)
  common=[str(binary),'--single-process-tests','--test-launcher-jobs=1','--test-launcher-retry-limit=0','--gtest_repeat=1','--gtest_shuffle=0','--gtest_color=no']
  discovery=base.captured_run(common+['--gtest_list_tests','--gtest_filter=NativeMediaRequestClassification.*'],binary.parent,env,out/'discovery.log',30);report['stages']['discovery']=discovery;require(discovery['exitCode']==0 and not discovery['timedOut'],'classification discovery failed/expired');require((out/'discovery.log').stat().st_size<=8*1024*1024,'discovery oversized');report['discoveredTests']=base.parse_discovery((out/'discovery.log').read_text(errors='strict'),expected);require(base.sha(binary)==before,'binary changed after discovery')
  xml=out/'results.xml';execution=base.captured_run(common+['--gtest_filter='+':'.join(expected),'--gtest_output=xml:'+str(xml)],binary.parent,env,out/'tests.log',300);report['stages']['execution']=execution;report['nativeExecutionAttempted']=True;require(execution['exitCode']==0 and not execution['timedOut'],'classification tests failed/crashed/expired');report['tests']=base.parse_xml(xml,expected);report['nativeTestsExecuted']=True;report['passedTestCount']=len(report['tests']);report['xmlSha256']=base.sha(xml);report['accepted']=True
 except Exception as failure:error=str(failure);report['error']={'type':type(failure).__name__,'message':error}
 finally:
  if before is not None:
   try:after=digest(binary)if binary.is_file()else None
   except OSError:after=None
   report['binarySha256After']=after
   if after!=before:report['accepted']=False;error=error or'binary changed during classification'
  if icu_before is not None:
   try:after=digest(icu)if icu.is_file()else None
   except OSError:after=None
   report['icuSha256After']=after;report['icuInputUnchanged']=after==icu_before
   if after!=icu_before:report['accepted']=False;error=error or'ICU changed during classification'
  if inputs:
   after={}
   for f in inputs:
    try:after[f]=digest(source/f)if(source/f).is_file()else None
    except OSError:after[f]=None
   report['sourceInputsAfter']=after;report['sourceInputsUnchanged']=after==inputs
   if after!=inputs:report['accepted']=False;error=error or'classification source drift'
  if original_files:
   try:after={f:digest(Path(f))if Path(f).is_file()else None for f in original_files}
   except OSError:after={}
   report['runnerInputsAfter']=after;report['runnerInputsUnchanged']=after==original_files
   if after!=original_files:report['accepted']=False;error=error or'runner/expectations drift'
  if error and 'error'not in report:report['error']={'type':'EvidenceDrift','message':error}
  (out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
 if error:print('Native classification proof refused: '+error,file=sys.stderr);return 1
 print('PASS exact11 on original exact35 binary; '+str(out/'results.json'));return 0
if __name__=='__main__':
 try:sys.exit(main())
 except Exception as failure:print('Native classification runner refused: '+str(failure),file=sys.stderr);sys.exit(1)
