#!/usr/bin/env python3
"""One separately instrumented main build, never acceptance/candidate code."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
from pair import require_focus_contract, run_with_focus_guard
BASE = '64fc763b1b7cf66855419eb455c55184a1a14d4c'

TRACE = r'''
@MainActor private enum ColumnStartupTrace {
    static var count = 0
    static let enabled = ProcessInfo.processInfo.environment["YAB_COLUMN_TRACE"] == "1"
    static func record(_ event: String, view: NSView? = nil, layer: CALayer? = nil,
                       out: Bool? = nil, requested: Bool? = nil, stack: Bool = false) {
        guard enabled, count < 1000 else { return }
        count += 1
        func id(_ object: AnyObject?) -> String {
            object.map { String(ObjectIdentifier($0).hashValue) } ?? "nil"
        }
        func rect(_ value: CGRect) -> [Double] {
            [value.minX, value.minY, value.width, value.height].map { Double($0) }
        }
        var row: [String: Any] = ["n": count, "event": event, "time": CACurrentMediaTime(),
            "view": id(view), "layer": id(layer), "superlayer": id(layer?.superlayer),
            "view_frame": rect(view?.frame ?? .zero), "layer_frame": rect(layer?.frame ?? .zero),
            "m41": Double(layer?.transform.m41 ?? 0), "window": view?.window?.windowNumber ?? -1,
            "out": out.map { $0 as Any } ?? NSNull(), "requested": requested.map { $0 as Any } ?? NSNull()]
        if stack { row["stack"] = Array(Thread.callStackSymbols.prefix(28)) }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print("COLUMN_TRACE " + text) }
    }
}
'''


def instrument(source):
    def once(old, new):
        nonlocal source
        assert source.count(old) == 1, old
        source = source.replace(old, new, 1)
    once('final class ColumnView: NSView {', TRACE + '\nfinal class ColumnView: NSView {')
    once('    private final class Host: NSHostingView<ColumnRoot> {\n        weak var browser: Browser?', r'''    private final class Host: NSHostingView<ColumnRoot> {
        weak var browser: Browser?
        private var tracedTransform: NSKeyValueObservation?
        override func makeBackingLayer() -> CALayer {
            let fresh = super.makeBackingLayer()
            ColumnStartupTrace.record("host.makeBackingLayer", layer: fresh, stack: true)
            if ColumnStartupTrace.enabled {
                tracedTransform = fresh.observe(\.transform, options: [.old, .new]) { layer, _ in
                    MainActor.assumeIsolated {
                        ColumnStartupTrace.record("host.transform.changed", layer: layer, stack: true)
                    }
                }
            }
            return fresh
        }
        override var frame: NSRect {
            willSet { ColumnStartupTrace.record("host.frame.willSet", view: self, layer: layer, stack: true) }
            didSet { ColumnStartupTrace.record("host.frame.didSet", view: self, layer: layer) }
        }
        override func layout() {
            ColumnStartupTrace.record("host.layout.before", view: self, layer: layer)
            super.layout()
            ColumnStartupTrace.record("host.layout.after", view: self, layer: layer)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ColumnStartupTrace.record("host.layout.nextTurn", view: self, layer: self.layer)
            }
        }
        override func viewDidMoveToWindow() {
            ColumnStartupTrace.record("host.window.before", view: self, layer: layer)
            super.viewDidMoveToWindow()
            ColumnStartupTrace.record("host.window.after", view: self, layer: layer)
        }''')
    once('''    override func layout() {
        super.layout()
        host.frame = bounds
    }''', '''    override func layout() {
        ColumnStartupTrace.record("column.layout.before", view: host, layer: host.layer, out: out)
        super.layout()
        host.frame = bounds
        ColumnStartupTrace.record("column.layout.after", view: host, layer: host.layer, out: out)
    }''')
    once('''    func slide(out now: Bool, animated: Bool) {
        defer { out = now }''', '''    func slide(out now: Bool, animated: Bool) {
        ColumnStartupTrace.record("slide.enter", view: host, layer: host.layer, out: out, requested: now, stack: true)
        defer {
            out = now
            ColumnStartupTrace.record("slide.exit", view: host, layer: host.layer, out: out, requested: now)
        }''')
    once('''        layer.setValue(target, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        guard let was = out, was != now else { return }''', '''        layer.setValue(target, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        ColumnStartupTrace.record("slide.applied", view: host, layer: layer, out: out, requested: now)
        guard let was = out, was != now else { return }''')
    return source


def main():
    assert os.environ.get('YAB_FARM_WORKER') == '1'
    out = Path(os.environ['YAB_FARM_OUT'])
    require_focus_contract(out, 'causal trace entry before source instrumentation/build or app launch')
    product = ROOT / 'Sources/Fast/Peek.swift'
    original = product.read_bytes()
    base = subprocess.check_output(['git', 'show', BASE + ':Sources/Fast/Peek.swift'], cwd=ROOT, text=True)
    traced = instrument(base)
    (out / 'traced-Peek.swift').write_text(traced)
    (out / 'instrumentation.patch').write_text(''.join(difflib.unified_diff(base.splitlines(True), traced.splitlines(True),
        fromfile='a/Sources/Fast/Peek.swift', tofile='b/Sources/Fast/Peek.swift')))
    (out / 'source.json').write_text(json.dumps({'base': BASE, 'kind': 'main plus observational hooks only; no fix',
        'base_peek_sha256': hashlib.sha256(base.encode()).hexdigest(),
        'traced_peek_sha256': hashlib.sha256(traced.encode()).hexdigest()}, indent=2))
    # rev_app's --with transports the one source into its separately locked
    # tracing rev tree. The job's frozen source is restored immediately after
    # building. The normal candidate tree is neither built nor accepted here.
    try:
        product.write_text(traced)
        with (out / 'trace-build.log').open('w') as log:
            child = subprocess.Popen(['bash', 'scripts/runs/rev_app.sh', BASE, str(out / 'trace.app'),
                                      '--with', 'Sources/Fast/Peek.swift'], cwd=ROOT,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in child.stdout: log.write(line); print(line, end='', flush=True)
            if child.wait(): return 2
    finally:
        product.write_bytes(original)
    sys.path.insert(0, str(Path(__file__).parent))
    import pair
    import http.server
    import threading
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), pair.Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # Env passes through probe_app's YAB_* transport; only this instrumented
    # binary reads it. Leave pristine pair.py and its saved apps untouched.
    original_launch = pair.launch
    def launch(*args, **kwargs):
        args = list(args); args[1] = dict(args[1], YAB_COLUMN_TRACE='1')
        return original_launch(*args, **kwargs)
    pair.launch = launch
    world = pair.World(out / 'trace.app', out / 'trace-proof/main35',
                       f'http://127.0.0.1:{server.server_port}', 35, True, False)
    report = world.run(); server.shutdown()
    return 0 if report.get('harness_completed') else 2


if __name__ == '__main__': sys.exit(run_with_focus_guard(main))
