#!/usr/bin/env python3
"""Production patch-companion filesystem regressions on fresh private fixtures.
No compilers, native source/cache writes, farm submissions or SDK acceptance.
"""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--stock62',type=Path,required=True);p.add_argument('--native77',type=Path,required=True);p.add_argument('--original-patches',type=Path,required=True);p.add_argument('--effective-patches',type=Path,required=True);p.add_argument('--work',type=Path,required=True);p.add_argument('--script',type=Path,default=Path(__file__).with_name('stock-context-native.sh'));a=p.parse_args()
assert not a.work.exists(),'fresh private work required; existing evidence is never removed';a.work.mkdir(parents=True)
names=['chrome_browser_browser.patch','chrome_browser_extensions.patch','webkit_plugin_info_2015.patch'];sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
paths=sorted(set(l[4:] for n in names for l in (a.original_patches/n).read_text().splitlines() if l.startswith('+++ ')));assert len(paths)==24
original={n:sha(a.original_patches/n) for n in names};effective={n:sha(a.effective_patches/n) for n in names}
def fixture(label,base,stock=a.original_patches):
 root=a.work/label;root.mkdir()
 for r in paths:
  f=root/r;f.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(base/r,f)
 for n in names:
  f=root/'cef/patch/patches'/n;f.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(stock/n,f)
 return root
def snapshot(root):return {r:sha(root/r) for r in paths}
def patch_snapshot(root):return {n:sha(root/'cef/patch/patches'/n) for n in names}
cases=[]
def run(root,mode,good=True,farm=True,locked=True):
 env=dict(os.environ);env['YAB_CHROMIUM_SRC']=str(root)
 env.pop('YAB_FARM_OUT',None);env.pop('YAB_OWNCEF_LOCKED',None)
 out=root/'private-out';out.mkdir(exist_ok=True)
 if farm:env['YAB_FARM_OUT']=str(out)
 if locked:env['YAB_OWNCEF_LOCKED']='1'
 result=subprocess.run(['bash',str(a.script),mode],env=env,text=True,capture_output=True)
 assert (result.returncode==0)==good,(root.name,result.stderr)
 if not good:return None
 return json.loads(result.stdout)
root=fixture('stock62-original',a.stock62);before=snapshot(root);m=run(root,'--check');assert all(r['selectedVariant']=='original' for r in m['patches']);assert snapshot(root)==before and patch_snapshot(root)==original;cases.append('known62 selects strict original, check is read-only')
root=fixture('native77-original',a.native77);before=snapshot(root);m=run(root,'--check');assert all(r['selectedVariant']=='effective' for r in m['patches']);assert snapshot(root)==before and patch_snapshot(root)==original;cases.append('known77 selects strict effective, check is read-only')
m=run(root,'--apply');assert snapshot(root)==before and patch_snapshot(root)==effective;assert all(r['afterSha256']==r['selectedSha256'] for r in m['patches']);cases.append('private apply changes only three context patch files')
m=run(root,'--apply');assert snapshot(root)==before and patch_snapshot(root)==effective;assert all(r['beforeSha256']==r['selectedSha256'] for r in m['patches']);cases.append('effective77 apply is idempotent')
root=fixture('stock62-effective-metadata',a.stock62,a.effective_patches);before=snapshot(root);m=run(root,'--apply');assert snapshot(root)==before and patch_snapshot(root)==original;assert all(r['selectedVariant']=='original' for r in m['patches']);cases.append('strict original62 recognition restores original metadata only')
root=fixture('partial-last-patch-source',a.native77);f=root/'third_party/blink/renderer/core/inspector/devtools_session.cc';s=f.read_text();assert '  Platform::Current()->DevToolsAgentAttached();' in s;f.write_text(s.replace('  Platform::Current()->DevToolsAgentAttached();','  /* missing upstream stock payload */'));before=snapshot(root);patches=patch_snapshot(root);run(root,'--apply',False);assert snapshot(root)==before and patch_snapshot(root)==patches;cases.append('partial third stock source refuses before any patch write')
root=fixture('unknown-last-stock-metadata',a.native77);f=root/'cef/patch/patches'/names[-1];f.write_bytes(f.read_bytes()+b'\nunknown stock mutation\n');before=snapshot(root);patches=patch_snapshot(root);run(root,'--apply',False);assert snapshot(root)==before and patch_snapshot(root)==patches;cases.append('unknown third stock hash refuses without earlier writes')
root=fixture('no-farm-output',a.native77);before=snapshot(root);patches=patch_snapshot(root);run(root,'--apply',False,farm=False);assert snapshot(root)==before and patch_snapshot(root)==patches;cases.append('apply requires farm output before writes')
root=fixture('no-source-lock',a.native77);before=snapshot(root);patches=patch_snapshot(root);run(root,'--apply',False,locked=False);assert snapshot(root)==before and patch_snapshot(root)==patches;cases.append('apply requires source lock before writes')
# Execute the actual SDK provenance assembly block, not a reimplemented model.
builder=a.script.with_name('build-source.sh').read_text();start=builder.index('# Separate provenance for the three native-overlay stock context adaptations.');end=builder.index("(folder / 'yab-owncef.json').write_text",start)
legacy={'upstreamPatch':'blink_ax_viewport_collapse.patch','schemaSentinel':['unchanged']};manifest={'stockPatchComposition':legacy}
exec(compile(builder[start:end],str(a.script.with_name('build-source.sh')),'exec'),{'out':a.work/'native77-original/private-out','json':json,'manifest':manifest})
assert manifest['stockPatchComposition'] is legacy and legacy=={'upstreamPatch':'blink_ax_viewport_collapse.patch','schemaSentinel':['unchanged']}
rows=manifest['stockNativePatchComposition']['patches'];assert len(rows)==3
for row in rows:
 assert row['originalSha256']==original[row['upstreamPatch']] and row['effectiveSha256']==effective[row['upstreamPatch']]
 assert row['selectedSha256']==effective[row['upstreamPatch']] and len(row['semanticsSha256'])==64
 assert row['stockReverseCheck'] and row['sparseReverseForwardRoundTrip'] and row['nativeFilesUnchanged']
cases.append('actual SDK provenance records all hashes without altering blink schema')
report={'cases':cases,'caseCount':len(cases),'allPassed':True,'productionCompanionExercised':True,'privateFixturesOnly':True,'nativeCompile':False,'sdkAcceptance':False};(a.work/'tests.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
