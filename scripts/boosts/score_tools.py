#!/usr/bin/env python3
"""Score recorded model selections, never run a tool or contact its site.

Input JSONL: {ask, expected:{tool,args}, actual:{tool,args}, model, revision}.
A model evaluation harness records its output here before executing any call.
"""
import argparse, json
from pathlib import Path

def score(rows):
    results=[]
    for row in rows:
        expected, actual = row['expected'], row.get('actual', {})
        passed = expected.get('tool') == actual.get('tool') and json.dumps(expected.get('args', {}), sort_keys=True) == json.dumps(actual.get('args', {}), sort_keys=True)
        results.append({'ask':row['ask'], 'model':row['model'], 'revision':row['revision'], 'passed':passed})
    return {'total':len(results), 'passed':sum(r['passed'] for r in results), 'results':results}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('recordings',type=Path);p.add_argument('--out',type=Path);a=p.parse_args()
    result=score([json.loads(line) for line in a.recordings.read_text().splitlines() if line.strip()])
    text=json.dumps(result,ensure_ascii=False,indent=2)
    if a.out:a.out.write_text(text+'\n')
    print(text)
    return 0 if result['total'] and result['total']==result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
