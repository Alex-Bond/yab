#!/usr/bin/env python3
"""Build-time plan and actual signer-derived compiled policy; no runtime authority.

No app launch/build/signing here. Explicit source generation precedes helper compile.
The helper never opens this JSON and acceptedVersion0 is not changed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid
from typing import NamedTuple, Optional

PREFIX='dev.serafim.yab.probe.gui.'
HEADER='original_parent_policy.generated.inc'
KIND='PRECOMPILE_CANDIDATE_PLAN_NOT_ACCEPTED_POLICY'
class CandidateBuildPlan(NamedTuple):
    bundle_id: str
    requirement: Optional[str]
    leaf_sha1: Optional[str]
    leaf_sha256: Optional[str]
    team: Optional[str]
    authority: Optional[str]
    header_sha256: Optional[str]
    signer_evidence: Optional[dict]

def digest(data): return hashlib.sha256(data).hexdigest()
def valid_id(value):
    if not isinstance(value,str) or not re.fullmatch(re.escape(PREFIX)+r'[0-9a-f]{16}',value):
        raise ValueError('Exact dedicated candidate ID required')
    return value

def requirement_for(actual_dr,source_id,candidate_id,leaf_sha1,team):
    """Controlled transform of an ACTUAL previously verified signer DR.

    Additional outer exact-ID/leaf/anchor constraints prevent a weak explicit DR
    from widening it. SHA1 is codesign's certificate-selector syntax, not our
    transport/image hash. Exact DER SHA256 is separately compiled/checked natively.
    """
    valid_id(candidate_id)
    if not re.fullmatch(r'[0-9a-f]{40}',leaf_sha1) or not re.fullmatch(r'[A-Z0-9]{10}',team): raise ValueError('Invalid actual signer')
    if not isinstance(actual_dr,str) or not 1<=len(actual_dr)<=16384 or any(ord(c)<32 or ord(c)>126 for c in actual_dr): raise ValueError('Unbounded/nonliteral actual DR')
    # codesign-generated identifier must be a single literal, not another clause.
    ids=re.findall(r'\bidentifier\s+"([^"\\]*)"',actual_dr)
    if ids != [source_id] or not isinstance(source_id,str) or not re.fullmatch(r'[A-Za-z0-9.-]{1,256}',source_id) or re.search(r'\bcdhash\b',actual_dr):
        raise ValueError('Cannot rebind ambiguous/parent-CDHash/foreign designated requirement')
    actual_dr=re.sub(r'\bidentifier\s+"'+re.escape(source_id)+r'"','identifier "'+candidate_id+'"',actual_dr,count=1)
    return '('+actual_dr+') and anchor apple generic and identifier "'+candidate_id+'" and certificate leaf = H"'+leaf_sha1+'" and certificate leaf[subject.OU] = "'+team+'"'

def run(argv):
    return subprocess.run([str(x) for x in argv],check=True,capture_output=True,timeout=180)

def signer_evidence(app,expected_leaf_sha1):
    """Only real native codesign verification/extraction creates these inputs.

    Existing installed codesign.1 documents -R, -r- and certificate0 DER leaf.
    expected_leaf_sha1 is the explicit chosen DeveloperID KEYCHAIN signer identity
    from the trusted build invocation, never decoded from a peer or plan.
    """
    if not re.fullmatch(r'[0-9a-f]{40}',expected_leaf_sha1): raise ValueError('Use exact selected signing certificate fingerprint')
    app=Path(app)
    if app.is_symlink() or app.suffix!='.app' or not app.is_dir(): raise ValueError('Actual signed reference app required')
    app=app.resolve(); info=app/'Contents/Info.plist'; original_info=info.read_bytes(); source_id=plistlib.loads(original_info).get('CFBundleIdentifier')
    if not isinstance(source_id,str): raise ValueError('No actual reference bundle identity')
    strict=['/usr/bin/codesign','--verify','--deep','--strict','--all-architectures']
    run(strict+[app])
    with tempfile.TemporaryDirectory(prefix='yab-precompile-signer-') as tmp:
        prefix=Path(tmp)/'certificate'
        out=run(['/usr/bin/codesign','-dvv','-r-','--extract-certificates',prefix,app])
        text=(out.stdout+out.stderr).decode('utf8','strict')
        chains=sorted(Path(tmp).glob('certificate*'),key=lambda p:int(p.name.removeprefix('certificate')))
        if not 2<=len(chains)<=8 or [p.name for p in chains]!=['certificate'+str(i) for i in range(len(chains))]: raise ValueError('Incomplete actual certificate chain')
        certs=[p.read_bytes() for p in chains]
        if any(not 1<=len(b)<=65536 for b in certs): raise ValueError('Bad actual DER chain')
        leaf_sha1=hashlib.sha1(certs[0]).hexdigest()
        if leaf_sha1!=expected_leaf_sha1: raise ValueError('Reference is not signed by the selected actual keychain signer')
        authorities=re.findall(r'^Authority=(.+)$',text,re.M); teams=re.findall(r'^TeamIdentifier=([A-Z0-9]{10})$',text,re.M)
        dr=re.findall(r'^designated => (.+)$',text,re.M); ids=re.findall(r'^Identifier=(.+)$',text,re.M)
        if not authorities or not authorities[0].startswith('Developer ID Application: ') or len(teams)!=1 or ids!=[source_id] or len(dr)!=1:
            raise ValueError('Actual DeveloperID/identifier/DR is missing or ambiguous')
        if not authorities[0].endswith(' ('+teams[0]+')') or not re.search(r'^CodeDirectory .*flags=0x[0-9a-f]+\([^\n]*\bruntime\b',text,re.M|re.I): raise ValueError('Original DeveloperID/runtime metadata mismatch')
        # Own DR extraction is never validation. Check original native code again
        # against its actual DR AND selected leaf+Apple anchor before issuing input.
        source_requirement='('+dr[0]+') and anchor apple generic and certificate leaf = H"'+leaf_sha1+'"'
        run(strict+['-R',source_requirement,app])
        if info.read_bytes()!=original_info: raise ValueError('Signed reference changed during inspection')
        return {'reference':str(app),'referenceIdentifier':source_id,'actualDesignatedRequirement':dr[0],
          'leafSHA1':leaf_sha1,'leafSHA256':digest(certs[0]),'chainSHA256':[digest(b) for b in certs],
          'team':teams[0],'authority':authorities[0],'infoSHA256':digest(original_info),
          'scope':'ACTUAL_CODESIGN_SIGNER_OBSERVATION_NOT_RUNTIME_AUTHORITY'}

def make_plan(bundle_id,evidence=None):
    valid_id(bundle_id)
    if evidence is None: return CandidateBuildPlan(bundle_id,None,None,None,None,None,None,None)
    req=requirement_for(evidence['actualDesignatedRequirement'],evidence['referenceIdentifier'],bundle_id,evidence['leafSHA1'],evidence['team'])
    plan=CandidateBuildPlan(bundle_id,req,evidence['leafSHA1'],evidence['leafSHA256'],evidence['team'],evidence['authority'],None,evidence)
    if not re.fullmatch(r'[0-9a-f]{64}',plan.leaf_sha256): raise ValueError('Exact actual certificate DER digest required')
    return plan._replace(header_sha256=digest(header_bytes(plan)))

def header_bytes(plan):
    if plan.requirement is None: raise ValueError('Default build has no issuer header')
    literal=lambda v:json.dumps(v,ensure_ascii=True)
    return ('// Trusted BUILD input; not a runtime manifest or accepted enable.\n'
      '#define YABCORE_COMPILED_PARENT_POLICY_VERSION 1\n'
      'static constexpr const char kYabCompiledParentIdentifier[] = '+literal(plan.bundle_id)+';\n'
      'static constexpr const char kYabCompiledParentLeafSHA256[] = '+literal(plan.leaf_sha256)+';\n'
      'static constexpr const char kYabCompiledParentRequirement[] = '+literal(plan.requirement)+';\n').encode()

def envelope(plan):
    return {'schema':1,'classification':KIND,'acceptedVersion':0,'nativePhaseAccepted':False,'commitAvailable':False,'plan':plan._asdict()}

def load_plan(path):
    row=json.loads(Path(path).read_text())
    if set(row)!={'schema','classification','acceptedVersion','nativePhaseAccepted','commitAvailable','plan'} or type(row['schema']) is not int or row['schema']!=1 or row['classification']!=KIND or type(row['acceptedVersion']) is not int or row['acceptedVersion']!=0 or row['nativePhaseAccepted'] is not False or row['commitAvailable'] is not False:
        raise ValueError('Not a typed unaccepted precompile plan')
    if not isinstance(row['plan'],dict) or set(row['plan'])!=set(CandidateBuildPlan._fields): raise ValueError('Unknown/missing plan fields')
    plan=CandidateBuildPlan(**row['plan']);valid_id(plan.bundle_id)
    if plan.requirement is None:
        if any(x is not None for x in plan[1:]): raise ValueError('Partial default issuer input')
    else:
        # This validation checks build consistency only, never mints live authority.
        if not isinstance(plan.signer_evidence,dict) or make_plan(plan.bundle_id,plan.signer_evidence)!=plan or digest(header_bytes(plan))!=plan.header_sha256: raise ValueError('Inconsistent precompile provenance')
    return plan

def verify_header(plan,path):
    path=Path(path) if path is not None else None
    if plan.requirement is None:
        if path is not None: raise ValueError('Default plan cannot supply a compiled policy path')
    elif path is None or path.is_symlink() or not path.is_file() or path.read_bytes()!=header_bytes(plan): raise ValueError('Exact precompiled policy input missing/changed')

def build_inputs(plan_path=None,header_path=None):
    # BUILD consistency/cache provenance only. Never consumed as runtime proof.
    if not plan_path:
        if header_path: raise ValueError('Header without typed precompile plan')
        return {'mode':'NO_PLAN_NO_HEADER','acceptedVersion':0,'candidateBundleIdentifier':None,
          'planSHA256':None,'headerSHA256':None,'signerLeafSHA1':None,'signerLeafSHA256':None,'requirementSHA256':None}
    plan=load_plan(plan_path); verify_header(plan,header_path)
    return {'mode':'COMPILED_UNACCEPTED_INPUT' if plan.requirement is not None else 'PLAN_NO_HEADER',
      'acceptedVersion':0,'candidateBundleIdentifier':plan.bundle_id,'planSHA256':digest(Path(plan_path).read_bytes()),
      'headerSHA256':plan.header_sha256,'signerLeafSHA1':plan.leaf_sha1,'signerLeafSHA256':plan.leaf_sha256,
      'requirementSHA256':digest(plan.requirement.encode()) if plan.requirement is not None else None}

def canonical_inputs(value): return json.dumps(value,sort_keys=True,separators=(',',':')).encode()

def fresh_write(path,data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    with os.fdopen(descriptor,'wb') as stream: stream.write(data);stream.flush();os.fsync(stream.fileno())

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--header',type=Path);p.add_argument('--bundle-id');p.add_argument('--signer-reference',type=Path);p.add_argument('--signer-sha1');a=p.parse_args()
    if bool(a.signer_reference)!=bool(a.signer_sha1): p.error('Both explicit actual signer inputs required')
    header=a.header
    if bool(header)!=bool(a.signer_reference): p.error('Explicit issuer requires a fresh build-output header; default has none')
    if a.out.exists() or (header is not None and (header.exists() or header.is_symlink())): raise ValueError('Precompile outputs already exist; no reissue/rebuild/re-sign')
    bundle_id=valid_id(a.bundle_id or PREFIX+uuid.uuid4().hex[:16])
    evidence=signer_evidence(a.signer_reference,a.signer_sha1) if a.signer_reference else None
    plan=make_plan(bundle_id,evidence)
    if plan.requirement is not None: fresh_write(header,header_bytes(plan))
    fresh_write(a.out,(json.dumps(envelope(plan),indent=2)+'\n').encode())
    print(json.dumps({'classification':KIND,'bundleIdentifier':bundle_id,'compiledPolicyInput':plan.requirement is not None,'acceptedVersion':0,'planSHA256':digest(a.out.read_bytes())}))
if __name__=='__main__':main()
