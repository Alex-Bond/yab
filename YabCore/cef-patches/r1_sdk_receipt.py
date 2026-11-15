"""Candidate runtime-build receipt checks, not release policy promotion."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def candidate_plan():
    path = Path(__file__).resolve().parent/'queue/native-candidate/plan.json'
    plan = json.loads(path.read_text())
    if plan.get('schema') != 1 or plan.get('baselinePatchCount') != 62:
        raise ValueError('Unknown pinned native candidate plan')
    return path, plan


def verify(sdk, expected_patches, runtime_only=False, native_candidate=False):
    key = sdk.parent.name
    if not re.fullmatch(r'wave(?:9|10)-[a-f0-9]{12}', key):
        raise ValueError('Only the reviewed wave9 baseline or wave10 candidate is admitted')
    if key.startswith('wave10-') and runtime_only:
        raise ValueError('A new wave10 SDK requires both native API modes and client proof')
    receipt = json.loads((sdk / 'yab-owncef.json').read_text())
    framework = sdk / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
    digest = hashlib.sha256()
    with framework.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): digest.update(block)
    actual = digest.hexdigest()
    if actual != receipt.get('frameworkSha256') or key.rsplit('-', 1)[1] != actual[:12]:
        raise ValueError('SDK framework bytes, receipt and directory key disagree')
    if key.startswith('wave10-'):
        count = 62
        if native_candidate:
            _, plan = candidate_plan()
            appended = {entry['output']: entry['sha256'] for entry in plan['patches']}
            if len(appended) != len(plan['patches']) or any(expected_patches.get(name) != digest for name, digest in appended.items()):
                raise ValueError('Native candidate differs from the pinned ordered source plan')
            count += len(appended)
        if len(expected_patches) != count or receipt.get('patches') != expected_patches:
            raise ValueError('Wave10 candidate must match the exact prepared source patch receipt')
    elif native_candidate:
        raise ValueError('Native candidate requires a new wave10 SDK and both API modes')
    elif any(receipt.get('patches', {}).get(name) != value for name, value in expected_patches.items()):
        raise ValueError('Wave9 baseline does not contain the expected source patches')
    header = (sdk / 'include/cef_browser.h').read_text()
    if 'CEF_YAB_EXTERNAL_ACTION_VERSION 1' not in header:
        raise ValueError('SDK lacks the original native action API')
    if native_candidate and any(marker not in header for marker in ['CEF_YAB_NATIVE_GROUP_OWNER_VERSION 1', 'CEF_YAB_ORIGINAL_PDF_PRESENCE_VERSION 1', 'CEF_YAB_NATIVE_GROUP_SOURCES_VERSION 1']):
        raise ValueError('Pinned native candidate lacks its original owner/PDF/source lifecycle APIs')
    if native_candidate and 'CEF_YAB_NATIVE_MEDIA_REQUEST_CLASSIFICATION_VERSION 1' not in (sdk / 'include/cef_permission_handler.h').read_text():
        raise ValueError('Pinned native candidate lacks immutable original media classification')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    expected = parser.add_mutually_exclusive_group(required=True)
    expected.add_argument('--source-wave', type=Path)
    expected.add_argument('--baseline-patches', type=Path)
    parser.add_argument('--runtime-only', action='store_true')
    parser.add_argument('--native-candidate', action='store_true')
    args = parser.parse_args()
    if args.native_candidate:
        if not args.source_wave: parser.error('--native-candidate requires --source-wave')
        path, _ = candidate_plan()
        source = json.loads(args.source_wave.read_text())
        if source.get('candidate', {}).get('planSHA256') != hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError('Prepared source wave is not bound to the current pinned candidate plan')
    patches = (json.loads(args.source_wave.read_text())['patches'] if args.source_wave else
               {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.baseline_patches.glob('[0-9][0-9][0-9][0-9]-*.patch')})
    receipt = verify(args.sdk, patches, args.runtime_only, args.native_candidate)
    args.out.write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
