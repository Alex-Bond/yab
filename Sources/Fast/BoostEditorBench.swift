import AppKit
import SwiftUI

/// Drives the production editor in a disposable test world for screenshots.
extension Bench {
    func boostEditorProbe(_ request: [String: Any], browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, let tab = browser.active else { answer(["error": "No test page"]); return }
        let editor = BoostEditor.shared
        if let open = request["open"] as? Bool {
            if open { editor.show(browser, tab: tab, siteControls: request["siteControls"] as? Bool == true) }
            else { editor.close() }
        }
        if let set = request["set"] as? [String: Any], editor.owns(tab) {
            editor.change(request["motion"] as? String ?? "direct") { look in
                if let n = set["hue"] as? Double { look.hue = min(360, max(0, n)) }
                if let n = set["amount"] as? Double { look.amount = min(1, max(0, n)) }
                if let n = set["size"] as? Double { look.size = min(1.6, max(0.85, n)) }
                if let n = set["spacing"] as? Double { look.spacing = min(2.5, max(0.5, n)) }
                if let n = set["photos"] as? Double { look.photos = min(1, max(0, n)) }
                if let n = set["font"] as? Int { look.font = min(7, max(0, n)) }
                if let n = set["textCase"] as? Int { look.textCase = min(2, max(0, n)) }
                if let mode = set["mode"] as? String, ["", "light", "dark"].contains(mode) { look.mode = mode }
            }
        }
        if let code = request["code"] as? Bool { withAnimation(Motion.reshape) { editor.code = code } }
        if let css = request["css"] as? String { editor.editCSS(css) }
        if let original = request["original"] as? Bool { editor.setOriginal(original) }
        if request["toggle"] as? Bool == true { editor.toggle(in: browser) }
        if request["picking"] as? Bool == true { editor.pick() }
        if let all = request["all"] as? Bool { editor.choose(all: all) }
        if request["undo"] as? Bool == true { browser.undoHiding() }
        if request["reset"] as? Bool == true { editor.reset() }
        func state() -> [String: Any] {
            func rect(_ value: CGRect?) -> [Double] {
                value.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } ?? []
            }
            let cursor = NSCursor.current
            var controls: [[String: Any]] = []
            if request["controls"] as? Bool == true, let window = tab.built?.window,
               let card = BoostEditorPointer.Area.screenRect(in: window), let root = window.contentView {
                var seen = Set<ObjectIdentifier>()
                func walk(_ object: Any) {
                    guard let node = object as? any NSAccessibilityProtocol,
                          seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
                    let frame = node.accessibilityFrame()
                    if card.intersects(frame), !frame.isEmpty {
                        controls.append(["label": node.accessibilityLabel() ?? node.accessibilityTitle() ?? "",
                                         "role": node.accessibilityRole()?.rawValue ?? "", "frame": rect(frame)])
                    }
                    for child in node.accessibilityChildren() ?? [] { walk(child) }
                }
                walk(root)
            }
            return ["open": editor.owns(tab), "look": editor.look.payload, "code": editor.code,
             "original": editor.original, "picking": browser.veiling, "draft": editor.draft,
             "groups": editor.hiddenGroups.map { ["id": $0.id, "label": $0.label, "count": $0.veils.count] as [String: Any] },
             "choice": editor.choice?.siblings.count ?? 0, "flights": editor.flights.count,
             "window": tab.builtPage?.window?.windowNumber ?? 0,
             "cursor": cursor == .arrow ? "arrow" : cursor == .iBeam ? "iBeam" : "other",
             "cursorUpdates": tab.built?.window.map { BoostEditorPointer.Area.cursorUpdates(in: $0) } ?? 0,
             "pointer": [NSEvent.mouseLocation.x, NSEvent.mouseLocation.y],
             "controls": controls,
             "cardScreen": rect(tab.built?.window.flatMap { BoostEditorPointer.Area.screenRect(in: $0) }),
             "originScreen": rect(editor.origin),
             "siteControlsScreen": rect(ExtensionPanel.shared.sourceRect)]
        }
        if let selector = request["pick"] as? String {
            tab.page.runInYab("""
            (()=>{const e=document.querySelector(\(BoostScript.json(selector)));if(!e)return null;
              const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()
            """) { value in
                guard let r = value as? [Double], r.count == 4 else { answer(["error": "No picked element"]); return }
                _ = editor.picked(tab, selector: selector, label: request["label"] as? String ?? selector,
                                  rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
                answer(state())
            }
        } else { answer(state()) }
    }
}
