import AppKit

// Test-world right-clicks on the bookmarks bar (feedback #153), for a hand
// that presses the real mouse (evals/bookmark-menu/hand.swift) or, with
// "post", presses queued for the window as the mouse queues them.
//
//   "list"    the bookmarks kept, as a tree of titles; those the row draws,
//             each with its middle on the screen (global, top-left), and the
//             window's frame there.
//   "listen"  every press from now on recorded, for "state".
//   "state"   the menus open now, front last: their frames on the screen,
//             their rows, and the row each has lit; where each press went
//             since "listen". Answered while a menu is being tracked.
//   "await"   the next menu to open, past those open now: its rows, picked
//             ("pick", by title; "Delete" picks "Delete…" too, as a click
//             would) and pictured ("path") once it is up, every menu then
//             closed; or, if none opens in "seconds", what happened instead
//             (the page in front, new tabs). With "post" and "name", a
//             right-click on that bookmark queued for the window first.
//             "presses": what the presses meanwhile went to.
extension Bench {
    private static var shelfWatching = false
    private static var shelfOpen: [NSMenu] = []
    private static var shelfPresses: [[String: Any]] = []
    private static var shelfListener: Any?

    /// Every menu the app tracks, from now on: a submenu, a context menu, a
    /// menu popped under a button.
    private static func shelfWatch() {
        guard !shelfWatching else { return }
        shelfWatching = true
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, menu != NSApp.mainMenu, !shelfOpen.contains(menu) else { return }
                shelfOpen.append(menu)
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                shelfOpen.removeAll { $0 === menu }
            }
        }
    }

    func shelfMenuCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "shelf-menu only works on a --test run"]); return }
        guard let window = Links.window, let content = window.contentView, let frameView = content.superview
        else { answer(["error": "no browser window"]); return }
        Self.shelfWatch()
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        /// A point of the window's, from its top-left, on the screen.
        func screen(_ point: CGPoint) -> [Double] {
            [Double(window.frame.minX + point.x), Double(top - window.frame.maxY + point.y)]
        }
        /// Where a press went: the view AppKit's hit test gives it, up to
        /// the window, and the menu that view offers.
        func describe(_ event: NSEvent) -> [String: Any] {
            var press: [String: Any] = ["type": event.type == .rightMouseDown ? "right" : "left",
                                        "window": event.window === window ? "browser" : String(describing: type(of: event.window as Any))]
            if event.window === window {
                var chain: [String] = []
                var offered: [String] = []
                var under = frameView.hitTest(event.locationInWindow)
                while let view = under, chain.count < 10 {
                    chain.append(String(describing: type(of: view)).prefix(80).description)
                    if offered.isEmpty, let menu = view.menu(for: event) { offered = menu.items.map(\.title) }
                    under = view.superview
                }
                press["hit"] = chain
                press["offered"] = offered
            }
            return press
        }
        switch request["act"] as? String ?? "list" {
        case "listen":
            // Every press from now on, for "state" to say where it went.
            if let listening = Self.shelfListener { NSEvent.removeMonitor(listening) }
            Self.shelfPresses = []
            Self.shelfListener = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                Self.shelfPresses.append(describe(event))
                return event
            }
            answer(["listening": true])

        case "list":
            func tree(_ nodes: [Bookmark]) -> [[String: Any]] {
                nodes.map { node in
                    var row: [String: Any] = ["title": node.title]
                    if let kids = node.children { row["children"] = tree(kids) } else { row["url"] = node.url ?? "" }
                    return row
                }
            }
            var row: [String: [Double]] = [:]
            for (name, rect) in Bench.spots where name.hasPrefix("bookmark ") {
                row[String(name.dropFirst("bookmark ".count))] = screen(CGPoint(x: rect.midX, y: rect.midY))
            }
            answer(["bookmarks": tree(browser.bookmarks.roots), "row": row.keys.sorted(), "at": row, "active": NSApp.isActive,
                    "window": [Double(window.frame.minX), Double(top - window.frame.maxY), Double(window.frame.width), Double(window.frame.height)]])

        case "state":
            let frames = Self.menuWindows().map { [Double($0.bounds.minX), Double($0.bounds.minY), Double($0.bounds.width), Double($0.bounds.height)] }
            answer(["menus": Self.shelfOpen.map { menu -> [String: Any] in
                ["rows": menu.items.filter { !$0.isSeparatorItem }.map(\.title), "lit": menu.highlightedItem?.title ?? ""]
            }, "frames": frames, "presses": Self.shelfPresses, "key": window.isKeyWindow, "active": NSApp.isActive])

        case "await":
            let before = Set(Self.shelfOpen.map(ObjectIdentifier.init))
            let page = browser.active?.address?.absoluteString ?? ""
            let tabs = browser.tabs.count
            let pick = request["pick"] as? String
            let path = request["path"] as? String
            let seconds = request["seconds"] as? Double ?? 3
            var out: [String: Any] = [:]
            // Where each press meanwhile went: the view AppKit's hit test
            // gives it, up to the window, and the menu that view offers.
            var presses: [[String: Any]] = []
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                presses.append(describe(event))
                return event
            }
            func done(_ menu: NSMenu?) {
                if let monitor { NSEvent.removeMonitor(monitor) }
                out["presses"] = presses
                out["menu"] = menu != nil
                if let menu {
                    out["items"] = Self.rows(menu)
                    if let path { out["saved"] = Self.picture(Self.menuWindows(), over: window, to: path) }
                }
                for open in Self.shelfOpen.reversed() { open.cancelTracking() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    // Every menu is down: one whose end went unannounced
                    // is not counted open for the next.
                    Self.shelfOpen = []
                    if let menu, let pick {
                        if let index = menu.items.firstIndex(where: { ($0.title == pick || $0.title == pick + "…") && $0.isEnabled }) {
                            out["picked"] = menu.items[index].title
                            menu.performActionForItem(at: index)
                        } else {
                            out["picked"] = ""
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        out["navigated"] = (browser.active?.address?.absoluteString ?? "") != page
                        out["active"] = browser.active?.address?.absoluteString ?? ""
                        out["tabs"] = browser.tabs.count - tabs
                        answer(out)
                    }
                }
            }
            if request["post"] as? Bool == true {
                guard let name = request["name"] as? String, let rect = Bench.spots["bookmark " + name] else {
                    answer(["error": "no bookmark named that in the row"]); return
                }
                let at = NSPoint(x: rect.midX, y: content.bounds.height - rect.midY)
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                      pressure: type == .rightMouseDown ? 1 : 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
            let started = CACurrentMediaTime()
            var seen: CFTimeInterval?
            let watch = Timer(timeInterval: 0.05, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    if let fresh = Self.shelfOpen.last(where: { !before.contains(ObjectIdentifier($0)) }), !Self.menuWindows().isEmpty {
                        // Up a moment, drawn, before it is read and pictured.
                        if seen == nil { seen = now }
                        if now - seen! > 0.3 { timer.invalidate(); done(fresh) }
                    } else if now - started > seconds {
                        timer.invalidate()
                        out["stillOpen"] = Self.shelfOpen.count
                        done(nil)
                    }
                }
            }
            RunLoop.main.add(watch, forMode: .common)

        default:
            answer(["error": "shelf-menu act: list, state or await"])
        }
    }
}
