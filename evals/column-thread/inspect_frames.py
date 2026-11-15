#!/usr/bin/env python3
"""Read the captured fixture frames: a narrow thumb must appear, then fade.

Run with Pillow against the fetched after/ folder. Content is at the same
offset in moving-4 and after; only the bar should change along its edge.
"""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageChops

parser = argparse.ArgumentParser()
parser.add_argument('folder', type=Path)
args = parser.parse_args()
report = json.loads((args.folder / 'report.json').read_text())
checks = []
for scene in report['scenes']:
    if not scene['state']['fixtureWindow'] or scene['name'].startswith('hidden'):
        continue
    active = [(s, axis) for s in scene['state']['scrolls']
              if s['window'] == scene['state']['fixtureWindow']
              for axis in ('vertical', 'horizontal')
              if s[axis] and s[axis].get('enabled') and s[axis].get('proportion', 1) < 1]
    if not active:
        continue
    scroll, axis = active[0]
    moving = Image.open(args.folder / (scene['name']+'-moving-4.png')).convert('RGB')
    after = Image.open(args.folder / (scene['name']+'-after.png')).convert('RGB')
    scale = moving.width / 600
    bar = scroll[axis].get('windowFrame')
    if not bar:
        raise RuntimeError('Capture needs the native scroller windowFrame')
    if axis == 'vertical':
        start = round(bar[0]*scale)
        strip = (start-2, 0, start+round(bar[2]*scale)+2, moving.height)
    else:
        start = moving.height-round((bar[1]+bar[3])*scale)
        strip = (0, start-2, moving.width, start+round(bar[3]*scale)+2)
    diff = ImageChops.difference(moving.crop(strip), after.crop(strip))
    mask = diff.convert('L').point(lambda v: 255 if v > 3 else 0)
    # Table grid lines move through the strip too. A thumb has a long
    # contiguous run along the scroll axis; the crossing grid lines do not.
    values = mask.tobytes()
    along, across = (mask.height, mask.width) if axis == 'vertical' else (mask.width, mask.height)
    columns, changed = [], 0
    for cross in range(across):
        start = None
        for at in range(along+1):
            index = at*mask.width+cross if axis == 'vertical' else cross*mask.width+at
            on = at < along and values[index] > 0
            if on and start is None:
                start = at
            elif not on and start is not None:
                if at-start >= 12*scale:
                    columns.append(cross)
                    changed += at-start
                start = None
    thickness = max(columns)-min(columns)+1 if columns else 0
    row = dict(scene=scene['name'], axis=axis, changed_pixels=changed,
               thickness_points=thickness/scale, crop=strip,
               passed=changed > 10 and 0 < thickness/scale <= 7)
    checks.append(row)
    print(('PASS ' if row['passed'] else 'FAIL ')+scene['name']+': '+str(row))
(args.folder / 'fade-checks.json').write_text(json.dumps(checks, indent=2))
raise SystemExit(0 if checks and all(c['passed'] for c in checks) else 1)
