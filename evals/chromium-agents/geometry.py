"""Screenshot coordinates hit the same trusted control at native CEF zoom."""
import base64
import io
import json
from pathlib import Path
import time
from PIL import Image
from agent_launch import require_page_window
from probe_capture import picture


def run(m, ask, out, prims, pid):
    tab, previous, shown = None, None, False
    summary = {'rows': []}
    try:
        tab = prims.tab_of(m('open', url=prims.BASE + '/button.html?task=' + prims.PREFIX + 'geometry'))
        previous = ask(do='chromium', id=tab, op='nav-zoom')['zoom']

        def script(body):
            return ask(do='chromium', id=tab, op='script', body=body)['value']

        script("""document.body.innerHTML = '<button id=zoomTarget style="position:absolute;left:90px;top:80px;width:140px;height:44px;border:0;border-radius:0;background:rgb(244,121,32)!important;color:black!important">Save draft</button>';
        globalThis.__zoomClicks = [];
        document.getElementById('zoomTarget').addEventListener('click', e => __zoomClicks.push(e.isTrusted));
        return true;""")
        for factor in (.75, 1.5, 2.0):
            got = ask(do='chromium', id=tab, op='nav-zoom', factor=factor)
            assert abs(got['zoom'] - factor) < .01, got
            # Script calls wait for ChromiumPage's queued zoom operation.
            box = script("const r=document.getElementById('zoomTarget').getBoundingClientRect();return {x:r.left+12,y:r.top+8,w:innerWidth};")
            shot = m.call_raw('tools/call', {'name': 'screenshot', 'arguments': {'tab': tab}})
            assert not shot.get('isError'), 'Ordinary zoomed screenshot was refused'
            block = next(item for item in shot['content'] if item.get('type') == 'image')
            data = base64.b64decode(block['data'], validate=True)
            image = Image.open(io.BytesIO(data)).convert('RGB')
            assert image.width == 1024, image.size
            x, y = box['x'] * 1024 / box['w'], box['y'] * 1024 / box['w']
            assert 0 <= x < image.width and 0 <= y < image.height, (box, image.size)
            pixel = image.getpixel((round(x), round(y)))
            assert pixel[0] > 180 and 40 < pixel[1] < 180 and pixel[2] < 100, (factor, pixel, box)
            path = Path(out) / ('zoom-' + str(factor).replace('.', '_') + '.jpg')
            path.write_bytes(data)
            before = len(script('return __zoomClicks'))
            m('click', tab=tab, x=x, y=y)
            until = time.monotonic() + 5
            clicks = script('return __zoomClicks')
            while len(clicks) == before and time.monotonic() < until:
                time.sleep(.1)
                clicks = script('return __zoomClicks')
            assert len(clicks) == before + 1 and all(clicks), clicks
            summary['rows'].append({'zoom': factor, 'passed': True, 'x': x, 'y': y,
                                    'pixel': pixel, 'trusted': True, 'picture': str(path)})
        m('show', tab=tab)
        shown = True
        state = require_page_window(ask, tab)
        path = Path(out) / 'zoom-window.png'
        metadata = picture(pid, path, window_id=state['window'])
        assert metadata.get('capture') == 'ScreenCaptureKit', metadata
        summary['picture'] = {'path': str(path), 'capture': metadata, 'zoom': 2.0}
        summary['passed'] = True
    finally:
        # Restore this isolated probe's site preference through the trusted
        # harness. No MCP operation acts in the handed-off tab afterward.
        if tab and previous is not None:
            try: ask(do='chromium', id=tab, op='nav-zoom', factor=previous)
            except Exception: pass
        if tab and not shown:
            try: m('close', tab=tab)
            except Exception: pass
        (Path(out) / 'geometry.json').write_text(json.dumps(summary, indent=2))
    return summary
