import AppKit
import WebKit

// Test-world hands on what a person does with an extension outside its
// popup (evals/extensions/onetab_user.py): its rows in a page's right-click
// menu, read and pressed by their titles as PageView.willOpenMenu adds
// them; its options page opened as the list's Options… opens it; and
// every tab of the window, each space's, with the place the extensions
// are told it has.
@available(macOS 15.4, *)
extension Bench {
    func extensionUserCommand(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "\(verb) only works on a --test run"]); return }
        let extensions = Extensions.of(browser)
        switch verb {
        case "ext-sign-ins":
            // Every sign-in's extensions: its list, what is loaded, the
            // tabs told to it, and the spaces signed in with it.
            answer(["here": extensions.signIn?.uuidString ?? "shared", "signIns": Extensions.all.map { each -> [String: Any] in
                ["signIn": each.signIn?.uuidString ?? "shared",
                 "spaces": browser.spaces.filter { Extensions.signIn(of: $0.id) == each.signIn }.map(\.name),
                 "installed": each.installed.map(\.id), "names": each.installed.map(\.name),
                 "loaded": each.contexts.keys.sorted(),
                 "told": (browser.tabs + browser.parkedTabs).filter(each.seen).map { $0.address?.absoluteString ?? "" },
                 "storage": Extensions.storageRoot(of: each.signIn)?.path ?? ""]
            }, "listed": Extensions.listed.map(\.uuidString)])
        case "ext-offscreen":
            // The process of its offscreen document, for an eval to end.
            let page = (request["id"] as? String).flatMap { ExtensionShims.offscreen[$0] }
            answer(["open": page != nil, "pid": Browser.process(of: page) ?? 0])
        case "ext-context":
            // "tab": the tab right-clicked (default: the one in front);
            // "press": the titles down to the row, ["OneTab", "Send only
            // this tab to OneTab"]. Answers with the rows, before the press.
            let tab = (request["tab"] as? String).flatMap { find(["id": $0], in: browser) } ?? browser.active
            guard let tab else { answer(["error": "no tab"]); return }
            let items = extensions.menuItems(for: tab)
            var out: [String: Any] = ["tab": Bench.short(tab), "items": Bench.extensionRows(items)]
            if let path = request["press"] as? [String], !path.isEmpty {
                var level = items
                var found: NSMenuItem?
                for (step, title) in path.enumerated() {
                    guard let item = level.first(where: { $0.title == title }) else { break }
                    if step == path.count - 1 { found = item } else { level = item.submenu?.items ?? [] }
                }
                guard let found, let action = found.action else {
                    out["error"] = "no row \(path.joined(separator: " › "))"
                    answer(out)
                    return
                }
                out["pressed"] = NSApp.sendAction(action, to: found.target, from: found)
            }
            answer(out)
        case "ext-options":
            guard let id = request["id"] as? String else { answer(["error": "ext-options needs an id"]); return }
            extensions.openOptions(id)
            answer(["opened": extensions.contexts[id]?.optionsPageURL?.absoluteString ?? ""])
        case "ext-everywhere":
            // The window's tabs space by space, and where each stands among
            // the tabs the extensions are told the window has.
            let told = extensions.visibleTabs(in: browser)
            func row(_ tab: Tab, _ space: String) -> [String: Any] {
                ["id": tab.id.uuidString.lowercased(), "url": tab.address?.absoluteString ?? "", "title": tab.title,
                 "asleep": tab.asleep, "pinned": tab.pin != nil, "kept": tab.kept, "bench": tab.bench,
                 "active": tab.id == browser.activeID, "space": space,
                 "told": extensions.told(tab) != nil, "view": tab.builtPage?.url?.absoluteString ?? "",
                 "index": told.firstIndex { $0.id == tab.id } ?? -1]
            }
            var tabs = browser.tabs.map { row($0, browser.space.name) }
            for space in browser.spaces where space.id != browser.spaceID {
                tabs += (browser.parked[space.id]?.tabs ?? []).map { row($0, space.name) }
            }
            answer(["space": browser.space.name, "tabs": tabs, "told": told.count])
        default:
            answer(Bench.unknown(verb))
        }
    }

    /// An extension's rows as a menu would show them, a submenu's under its row.
    static func extensionRows(_ items: [NSMenuItem]) -> [[String: Any]] {
        items.filter { !$0.isSeparatorItem }.map { item in
            var row: [String: Any] = ["title": item.title, "enabled": item.isEnabled, "on": item.state == .on]
            if let sub = item.submenu { row["submenu"] = extensionRows(sub.items) }
            return row
        }
    }
}
