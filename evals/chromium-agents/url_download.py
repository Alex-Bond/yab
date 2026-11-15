"""URL-only MCP download: actual native CEF item, task ownership and bytes."""
import json
from pathlib import Path
import re


def run(m, ask, out, prims):
    snap = m('open', url=prims.BASE + '/download.html?task=url-download')
    tab = prims.tab_of(snap)
    result = {'checks': []}
    try:
        state = ask(do='chromium', id=tab)
        assert state['engine'] == 'chromium', state
        for url in (prims.BASE + '/report.csv', '/report.csv'):
            reply = m('download', tab=tab, url=url)
            assert reply.startswith('Saved: '), reply
            path = Path(reply.removeprefix('Saved: ').strip())
            text = path.read_text()
            assert path.name.startswith('august-report') and path.suffix == '.csv', str(path)
            assert len(text.splitlines()) == 31 and text.startswith('date,customer,status,amount\n'), text[:100]
            result['checks'].append({'url': url, 'path': str(path), 'bytes': path.stat().st_size, 'passed': True})
        result['passed'] = True
        return result
    finally:
        (out / 'url-download.json').write_text(json.dumps(result, indent=2))
        m('close', tab=tab)
