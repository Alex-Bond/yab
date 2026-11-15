#!/usr/bin/env python3
"""Small regression of production ClickAway event order, without a browser build.

Compiles the entire real controller, with its actual monitor mask and the
field's actual constructor from Browser.swift. The same checks run on base
and candidate; only the premature mouse-down dismissal may fail on base.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(label, controller, browser, out):
    constructor = re.search(r"let away = (ClickAway(?:\(on: \[[^\]]+\]\))?) \{ \[weak self\] in", browser)[1]
    mask = re.search(r"let observed = (.+)", controller)
    if mask:
        mask = mask[1]
    else:
        mask = re.search(r"addLocalMonitorForEvents\(matching: (\[[^\]]+\])\)", controller)[1]
    harness = r'''
extension ClickAway {
    func fixture(_ type: NSEvent.EventType, inside: Bool = false) {
        guard clicks != nil else { return }
        let observed: NSEvent.EventTypeMask = MASK
        guard observed.contains(NSEvent.EventTypeMask(rawValue: 1 << type.rawValue)) else { return }
        let event = NSEvent.mouseEvent(with: type, location: inside ? NSPoint(x: 20, y: 20) : NSPoint(x: 300, y: 200),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        clicked(event)
    }
}
@main struct EventOrderProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks: [String: Bool] = [:]
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        var calls = 0
        let field = CONSTRUCTOR { calls += 1 }
        field.watch(true)
        field.fixture(.leftMouseDown); drain()
        checks["no_dismissal_before_row_selection"] = calls == 0
        field.fixture(.leftMouseUp); drain()
        checks["outside_release_dismisses_once"] = calls == 1
        field.watch(false)
        calls = 0
        let zone = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        field.zones.add(zone)
        field.watch(true)
        field.fixture(.leftMouseDown, inside: true); drain()
        field.fixture(.leftMouseUp); drain()
        checks["text_drag_from_inside_stays_open"] = calls == 0
        field.watch(false)
        field.fixture(.leftMouseDown); field.fixture(.leftMouseUp); drain()
        checks["stopped_monitor_does_nothing"] = calls == 0
        field.watch(true)
        field.fixture(.rightMouseDown); drain()
        checks["right_click_still_dismisses"] = calls == 1
        field.watch(false)
        calls = 0
        let menu = ClickAway { calls += 1 }
        menu.watch(true)
        menu.fixture(.leftMouseDown); drain()
        checks["other_menus_keep_mouse_down_behavior"] = calls == 1
        menu.watch(false)
        print(String(data: try! JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), encoding: .utf8)!)
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
'''.replace("MASK", mask).replace("CONSTRUCTOR", constructor)
    source = out / (label + ".swift")
    source.write_text(controller + "\n" + harness)
    binary = out / label
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(source), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE)
    print(label, result.stdout, flush=True)
    checks = json.loads(result.stdout.strip().splitlines()[-1])
    return {"exit": result.returncode, "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    args = parser.parse_args()
    if os.environ.get("YAB_FARM_WORKER") != "1":
        parser.error("run through ./farm exec")
    out = Path(os.environ["YAB_FARM_OUT"]) / "event-order"
    out.mkdir(parents=True, exist_ok=True)
    paths = ["Sources/Fast/ClickAway.swift", "Sources/Fast/Browser.swift"]
    before = run("before", *(subprocess.check_output(["git", "show", args.base + ":" + p], cwd=ROOT, text=True) for p in paths), out)
    after = run("after", *((ROOT / p).read_text() for p in paths), out)
    failures = [key for key, passed in before["checks"].items() if not passed]
    report = {"base": args.base, "before": before, "after": after,
              "passed": before["exit"] == 1 and failures == ["no_dismissal_before_row_selection"] and after["exit"] == 0}
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
