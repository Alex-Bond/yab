import AppKit
import YabCoreClient

/// Own CEF: a page's <select> popup drawn by Yab as a native menu at the
/// element, instead of Chromium's menu in the hidden producer window. The
/// helper sends select.open with root-page DIP geometry and items, and
/// select.closed when the page withdraws it. Exactly one select.reply goes
/// back per token, with the chosen index or -1.
@MainActor
extension ChromiumPage {
    func receiveSelect(_ p: [String: JSONValue]) {
        guard let token = p["token"]?.number, case .array(let rows)? = p["items"], window != nil else {
            if let token = p["token"]?.number { replySelect(Int(token), -1) }
            return
        }
        selectMenu?.cancelTracking()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let size = p["fontSize"]?.number ?? 0
        if size > 0 { menu.font = .menuFont(ofSize: size) }
        for (index, row) in rows.enumerated() {
            guard case .object(let item) = row else { continue }
            let type = item["type"]?.string ?? "option"
            if type == "separator" { menu.addItem(.separator()); continue }
            let label = item["label"]?.string ?? ""
            let entry: NSMenuItem
            if type == "group" {
                entry = NSMenuItem.sectionHeader(title: label)
            } else {
                entry = NSMenuItem(title: label, action: #selector(SelectChoice.pick(_:)), keyEquivalent: "")
                entry.isEnabled = item["enabled"] == .bool(true) && type != "submenu"
                if item["checked"] == .bool(true) { entry.state = .on }
            }
            entry.tag = index
            entry.toolTip = item["toolTip"]?.string.flatMap { $0.isEmpty ? nil : $0 }  // design: the page's own option title, shown like a native select does
            menu.addItem(entry)
        }
        let picker = SelectChoice()
        for entry in menu.items where entry.action != nil { entry.target = picker }
        let selected = Int(p["selected"]?.number ?? -1)
        let x = p["x"]?.number ?? 0, y = p["y"]?.number ?? 0, h = p["height"]?.number ?? 0
        // Root-page DIP has a top-left origin; this view is not flipped.
        let anchor = NSPoint(x: x, y: bounds.height - y - h)
        selectMenu = menu
        selectToken = Int(token)
        // Present after this event is handled: the menu tracks in a nested
        // run loop, during which select.closed can still cancel it.
        Task { @MainActor [weak self] in
            guard let self, self.selectToken == Int(token) else { return }
            let item = menu.items.first { $0.tag == selected && $0.action != nil }
            menu.popUp(positioning: item, at: anchor, in: self)
            if self.selectToken == Int(token) {
                self.selectToken = nil; self.selectMenu = nil
                self.replySelect(Int(token), picker.chosen)
            }
        }
    }

    func closeSelect(_ p: [String: JSONValue]) {
        guard let token = p["token"]?.number, selectToken == Int(token) else { return }
        selectToken = nil
        selectMenu?.cancelTracking(); selectMenu = nil
    }

    private func replySelect(_ token: Int, _ index: Int) {
        Task { @MainActor [weak self] in
            _ = try? await self?.navigationRequest("select.reply", ["token": .number(Double(token)), "index": .number(Double(index))])
        }
    }
}

/// Target for the select menu's items; reports the chosen item's index.
@MainActor
final class SelectChoice: NSObject {
    private(set) var chosen = -1
    @objc func pick(_ sender: NSMenuItem) { chosen = sender.tag }
}
