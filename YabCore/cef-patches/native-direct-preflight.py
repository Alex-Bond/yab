#!/usr/bin/env python3
"""Actual current-GN objects, isolated diagnostics; not final Ninja/link proof."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib,json,os,re,shlex,subprocess,sys,time

HERE=Path(__file__).resolve().parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    assert os.environ.get('YAB_OWNCEF_LOCKED')=='1','source lock required'
    assert os.environ.get('YAB_FARM_OUT'),'farm output required'
    assert os.getpriority(os.PRIO_PROCESS,0)>=10,'source compiler nice10 required'
    src=Path(os.environ.get('YAB_CHROMIUM_SRC',str(Path.home()/'chromium/src'))).resolve()
    build=src/'out/Release_GN_arm64'
    dest=(Path(os.environ['YAB_FARM_OUT'])/'native-direct-preflight').resolve()
    dest.mkdir(parents=True,exist_ok=False)
    jobs=int(os.environ.get('YAB_OWNCEF_JOBS','4'));load=float(os.environ.get('YAB_OWNCEF_LOAD','6'))
    assert 1<=jobs<=4 and 0<load<=6
    targets=re.findall(r'^  (obj/\S+\.o)$',(HERE/'native-object-preflight.sh').read_text(),re.M)
    assert len(targets)==43 and len(set(targets))==43
    metadata={str(p.relative_to(build)):sha(p) for p in build.rglob('*.ninja')}
    commands={}
    # Query THIS configured graph, never reuse an older source60 argv receipt.
    proc=subprocess.Popen(['ninja','-C',str(build),'-t','commands',*targets],
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,errors='replace')
    for line in proc.stdout:
        match=re.search(r'(?:^|\s)-o\s+(\S+)',line)
        if not match or match.group(1) not in targets:continue
        assert '\ufffd' not in line
        argv=shlex.split(line);target=match.group(1)
        assert argv.count('-o')==argv.count('-MF')==argv.count('-c')==1
        assert Path(argv[0]).name in ('clang++','clang')
        assert '-fmodules' not in argv or '-fno-implicit-modules' in argv,'no implicit shared module-cache writes'
        assert not any(a.startswith('@') or a in ('-MJ','-serialize-diagnostics','-save-temps','-gsplit-dwarf','-emit-module','-fsyntax-only') or a.startswith(('-ftime-trace','-fprofile-generate')) for a in argv)
        source=(build/argv[argv.index('-c')+1]).resolve()
        assert source.is_relative_to(src) and source.is_file()
        commands[target]={'argv':argv,'source':str(source.relative_to(src)),'sourceSha256':sha(source),'commandSha256':hashlib.sha256(line.rstrip('\n').encode()).hexdigest()}
    err=proc.stderr.read();assert proc.wait()==0,err
    assert set(commands)==set(targets)
    # This is diagnostic codegen, not graph ownership: output only to fresh jobout.
    def compile_one(pair):
        target,record=pair;argv=record['argv'].copy()
        unit=dest/target;unit.parent.mkdir(parents=True,exist_ok=True)
        argv[argv.index('-o')+1]=str(unit);argv[argv.index('-MF')+1]=str(unit)+'.d'
        temporary=Path(str(unit)+'.tmp');temporary.mkdir()
        crash=Path(str(unit)+'.crash');crash.mkdir()
        crash_flags=[n for n,arg in enumerate(argv) if arg.startswith('-fcrash-diagnostics-dir=')]
        assert len(crash_flags)<=1
        if crash_flags:argv[crash_flags[0]]='-fcrash-diagnostics-dir='+str(crash)
        else:argv.append('-fcrash-diagnostics-dir='+str(crash))
        child_env=os.environ.copy();child_env['TMPDIR']=str(temporary)
        while os.getloadavg()[0]>load:time.sleep(1)
        print('direct native CXX '+target,flush=True)
        code=None;exception=None
        with Path(str(unit)+'.log').open('w') as log:
            try:
                run=subprocess.run(argv,cwd=build,stdout=log,stderr=subprocess.STDOUT,timeout=1800,env=child_env)
                code=run.returncode
            except (subprocess.TimeoutExpired,OSError) as error:
                exception={'type':type(error).__name__,'message':str(error)}
                log.write('\nDIAGNOSTIC EXCEPTION '+repr(exception)+'\n')
        result={**record,'isolatedArgv':argv,'temporaryDirectory':str(temporary),'crashDirectory':str(crash),'exitCode':code,'exception':exception,'log':str(unit)+'.log','objectSha256':sha(unit) if code==0 and unit.is_file() else None}
        return target,result
    with ThreadPoolExecutor(max_workers=jobs) as pool:results=dict(pool.map(compile_one,commands.items()))
    failed=[(t,r) for t,r in results.items() if r['exitCode']!=0]
    generated=set()
    if failed:
        # Exact declared Ninja generated output required. No generic missing
        # header/type error is classified as a prerequisite limitation.
        p=subprocess.Popen(['ninja','-C',str(build),'-t','targets','all'],stdout=subprocess.PIPE,text=True,errors='replace')
        for line in p.stdout:
            name=line.split(': ',1)[0]
            if name.startswith('gen/'):generated.add(name)
        assert p.wait()==0
    product_errors=[];prerequisites=[]
    for target,record in failed:
        log=Path(record['log']).read_text(errors='replace')
        errors=re.findall(r'^.*(?:fatal error:|error:).*$' ,log,re.M)
        missing=re.findall(r"fatal error: ['\"]([^'\"]+)['\"] file not found",log)
        known=[]
        for header in missing:
            rel=header if header.startswith('gen/') else 'gen/'+header
            if rel in generated and not (build/rel).exists():known.append(rel)
        prerequisite=not record['exception'] and bool(errors) and len(errors)==len(missing)==len(known)
        record['classification']='generated-prerequisite-unavailable' if prerequisite else 'compiler-error'
        record['missingDeclaredGeneratedOutputs']=known
        (prerequisites if prerequisite else product_errors).append(target)
        print(record['classification']+' '+target+': '+record['log'],flush=True)
    final_metadata={str(p.relative_to(build)):sha(p) for p in build.rglob('*.ninja')}
    unchanged=metadata==final_metadata
    source_drift=[]
    for target,record in results.items():
        source=src/record['source']
        final=sha(source) if source.is_file() else None
        record['finalSourceSha256']=final
        if final!=record['sourceSha256']:source_drift.append(target)
    receipt={'scope':'isolated real current GN C++/ObjC++ codegen only; final Ninja41 and framework link mandatory','compileExecuted':True,'nativeRuntime':False,'jobs':jobs,'load':load,'metadata':metadata,'metadataUnchanged':unchanged,'finalMetadata':final_metadata,'sourceDrift':source_drift,'sourcesUnchanged':not source_drift,'objects':results,'compilerErrors':product_errors,'generatedPrerequisitesUnavailable':prerequisites,'finalNinjaRequired':True}
    (dest/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return 1 if product_errors or source_drift or not unchanged else 0
if __name__=='__main__':sys.exit(main())
