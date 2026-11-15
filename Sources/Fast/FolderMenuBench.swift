import AppKit
import SwiftUI

// Test-world access to a folder's right-click menu (NestMenu), the same rows
// a person sees: "read" lists them, "pick" chooses one by its title and says
// what the clipboard then holds, "show" opens it over the browser window and
// pictures it at "path", as the window server puts it together.
extension Bench {
    func folderMenuCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "folder-menu only works on a --test run"]); return }
        guard let window = Links.window, let content = window.contentView else { answer(["error": "folder-menu needs a browser window"]); return }
        // A right press ("control": a Control-click) at "at" in the window,
        // top-left, handed to the app as the mouse's own: the views it went
        // to, then the menu as it opened (ActionMenu.state), or none.
        if request["act"] as? String == "press" {
            guard let at = request["at"] as? [Double], at.count == 2 else { answer(["error": "press needs at"]); return }
            let control = request["control"] as? Bool == true
            let point = NSPoint(x: at[0], y: content.bounds.height - at[1])
            guard let event = NSEvent.mouseEvent(with: control ? .leftMouseDown : .rightMouseDown, location: point,
                                                 modifierFlags: control ? .control : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { answer(["error": "no event"]); return }
            ActionMenu.close()
            var hit: [String] = []
            let watch = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { seen in
                MainActor.assumeIsolated {
                    var under = content.hitTest(point)
                    while let view = under, hit.count < 10, view !== content {
                        hit.append(String(describing: type(of: view)))
                        under = view.superview
                    }
                }
                return seen
            }
            if !window.isKeyWindow { window.makeKey() }
            NSApp.sendEvent(event)
            watch.map(NSEvent.removeMonitor)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var out = ActionMenu.state()
                out["hit"] = hit
                if let path = request["path"] as? String, let frame = out["frame"] as? [CGFloat], let id = out["window"] as? Int {
                    let bounds = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]).insetBy(dx: -ActionMenu.room, dy: -ActionMenu.room)
                    out["saved"] = Self.picture([(CGWindowID(id), bounds)], over: ActionMenu.parentWindow ?? window, to: path)
                }
                if request["keep"] as? Bool != true { ActionMenu.close() }
                answer(out)
            }
            return
        }
        // The menu a right-click on the folder's row opens (SteadyMenu.swift),
        // or with "id" and no folder, the one a tab's row opens (TabMenu).
        let menu: NSMenu
        if let name = request["folder"] as? String, let nest = browser.nests.first(where: { $0.name == name }) {
            menu = NSHostingMenu(rootView: NestMenu(browser: browser, nest: nest))
        } else if let titles = request["items"] as? [String] {
            // A menu of only these lines ("-" a line between), to see a
            // short menu's sizes.
            menu = NSMenu()
            menu.autoenablesItems = false
            for title in titles {
                menu.addItem(title == "-" ? .separator() : NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        } else if request["folder"] == nil, let tab = find(request, in: browser) {
            menu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: tab, close: { browser.shut(tab) }))
        } else {
            answer(["error": "folder-menu needs a folder, or a tab's id"]); return
        }
        menu.appearance = window.effectiveAppearance
        menu.update()
        ActionMenu.prepare(menu)
        switch request["act"] as? String ?? "read" {
        case "panel":
            // The menu as the right-click shows it now (ActionMenu.swift),
            // hung from "at" in the window, top-left; then "type", "take"
            // and "key" in turn, and at "path" its picture over the window.
            if !ActionMenu.isOpen || request["at"] != nil {
                // A negative height is up from the window's foot.
                let at = request["at"] as? [Double] ?? [180, 120]
                let down = at[1] < 0 ? content.bounds.height + at[1] : at[1]
                let point = window.convertPoint(toScreen: NSPoint(x: at[0], y: content.bounds.height - down))
                ActionMenu.show(menu, in: window, at: point)
            }
            ActionMenu.bench(type: request["type"] as? String, point: request["point"] as? String,
                             take: request["take"] as? String, key: request["key"] as? String, option: request["option"] as? Bool, letters: request["letters"] as? String)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var out = ActionMenu.state()
                // The panel and the submenus beside it, in one picture.
                if let path = request["path"] as? String {
                    let shown = [out] + (out["children"] as? [[String: Any]] ?? [])
                    let windows = shown.compactMap { one -> (id: CGWindowID, bounds: CGRect)? in
                        guard let id = one["window"] as? Int, let frame = one["frame"] as? [CGFloat] else { return nil }
                        let bounds = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]).insetBy(dx: -ActionMenu.room, dy: -ActionMenu.room)
                        return (CGWindowID(id), bounds)
                    }
                    if !windows.isEmpty {
                        let area = windows.map(\.bounds).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -28, dy: -28)
                        out["captureBounds"] = [area.minX, area.minY, area.width, area.height]
                        let background = ActionMenu.parentWindow ?? window
                        out["capturedWindowIDs"] = windows.map { Int($0.id) } + [background.windowNumber]
                        out["saved"] = Self.picture(windows, over: background, to: path)
                    }
                }
                if request["keep"] as? Bool != true { ActionMenu.close() }
                answer(out)
            }
        case "pick":
            // "title", or "path": the titles down the submenus to the line,
            // as ["Move to Space", "🌿  Work", "Kept"].
            let path = request["path"] as? [String] ?? [request["title"] as? String ?? ""]
            var level = menu
            for name in path.dropLast() {
                // A space by its name alone, its emoji before it.
                guard let inner = level.items.first(where: { $0.title == name || $0.title.hasSuffix("  " + name) })?.submenu else {
                    answer(["error": "no submenu named \(name)"]); return
                }
                inner.update()
                level = inner
            }
            let title = path.last ?? ""
            guard let index = level.items.firstIndex(where: { $0.title == title || $0.title.hasSuffix("  " + title) }), level.items[index].isEnabled
            else { answer(["error": "no enabled item named \(title)"]); return }
            level.performActionForItem(at: index)
            answer(["picked": title, "clipboard": NSPasteboard.general.string(forType: .string) ?? ""])
        case "show":
            let path = request["path"] as? String
            // Menu tracking runs a loop of its own: the picture is taken in it.
            let watch = Timer(timeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    var out: [String: Any] = ["items": Self.rows(menu)]
                    if let path { out["saved"] = Self.picture(Self.menuWindows(), over: window, to: path) }
                    menu.cancelTracking()
                    answer(out)
                }
            }
            RunLoop.main.add(watch, forMode: .common)
            let point = (request["at"] as? [Double]).map { NSPoint(x: $0[0], y: content.bounds.height - $0[1]) }
                ?? NSPoint(x: 180, y: content.bounds.height - 120)
            // "around": the row by that title put under the point, so a
            // long menu on a short window shows it rather than scrolling.
            let around = (request["around"] as? String).flatMap { title in menu.items.first { $0.title == title } }
            menu.popUp(positioning: around, at: around == nil ? point : NSPoint(x: point.x, y: content.bounds.height / 2), in: content)
        default:
            answer(["items": Self.rows(menu)])
        }
    }
}
