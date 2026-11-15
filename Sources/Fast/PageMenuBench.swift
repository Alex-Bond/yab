import AppKit

// Test-world pictures of a page's own right-click menu: the one WebKit opens
// and PageView.willOpenMenu adds to, right-clicked at a point of the page in
// front. "open": a row whose submenu is opened as a person would from the
// keyboard, ↓ down to it and →. "press": a row chosen, as a click on it
// would, a submenu's by "Row/Row" (the one "open" opened). "path": the menus as the window
// server puts them together over the window, which a layer render never
// draws; the app's own windows need no permission. The menu closes after.
extension Bench {
    private static var pageMenuWatch: Timer?
    private static var pageMenuSeen: NSObjectProtocol?
    private static var pageMenu: NSMenu?
    private static var pageMenuTyped: CFTimeInterval?

    func pageMenuCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "page-menu only works on a --test run"]); return }
        guard let web = browser.active?.builtPage, let window = web.window else { answer(["error": "no page in a window"]); return }
        Self.pageMenuWatch?.invalidate()
        Self.pageMenu = nil
        if let seen = Self.pageMenuSeen { NotificationCenter.default.removeObserver(seen) }
        Self.pageMenuSeen = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                if Self.pageMenu == nil, let menu = note.object as? NSMenu, menu != NSApp.mainMenu { Self.pageMenu = menu }
            }
        }
        let at = request["at"] as? [Double] ?? [240, 160]
        let local = CGPoint(x: at[0], y: web.isFlipped ? at[1] : web.bounds.height - at[1])
        let point = web.convert(local, to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { answer(["error": "no mouse event"]); return }
            type == .rightMouseDown ? web.rightMouseDown(with: event) : web.rightMouseUp(with: event)
        }
        let open = request["open"] as? String
        // AppKit's AutoFill row is attached by its menu implementation,
        // outside NSMenu.items. It is the last row on editable field menus.
        let systemAutofill = request["openSystemAutofill"] as? Bool == true
        let path = request["path"] as? String
        let hold = min(3, max(0, request["hold"] as? Double ?? 0))
        let started = CACurrentMediaTime()
        Self.pageMenuTyped = nil
        // WebKit asks the page first and opens the menu a moment later, in a
        // loop of its own: this watch runs in it.
        let watch = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let menus = Self.menuWindows()
                let now = CACurrentMediaTime()
                if menus.isEmpty {
                    if now - started > 6 { timer.invalidate(); answer(["error": "no menu opened"]) }
                    return
                }
                if systemAutofill, Self.pageMenuTyped == nil {
                    Self.pageMenuTyped = now
                    Self.press(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
                    Self.press(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
                    return
                }
                if let open, Self.pageMenuTyped == nil {
                    Self.pageMenuTyped = now
                    // "Translate To/More Languages": a submenu in a submenu.
                    // Opened by its arrow, a submenu has its first row lit.
                    var menu = Self.pageMenu
                    for (depth, title) in open.split(separator: "/").map(String.init).enumerated() {
                        let rows = menu?.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.isEnabled } ?? []
                        guard let index = rows.firstIndex(where: { $0.title == title }) else { return }
                        for _ in 0..<(depth == 0 ? index + 1 : index) { Self.press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125) }
                        Self.press(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
                        menu = rows[index].submenu
                    }
                    return
                }
                if let typed = Self.pageMenuTyped, now - typed < 0.6 { return }
                if now - started < hold { return }
                timer.invalidate()
                var out: [String: Any] = ["menus": menus.count]
                if let menu = Self.pageMenu { out["items"] = Self.rows(menu) }
                if let path { out["saved"] = Self.picture(menus, over: window, to: path) }
                let menu = Self.pageMenu
                menu?.cancelTracking()
                Self.pageMenu = nil
                // Test the text-input-client boundary used by the system
                // picker with a fixture value, without opening a real vault.
                if let text = request["insertSystemText"] as? String {
                    DispatchQueue.main.async {
                        window.makeFirstResponder(web)
                        web.insertText(text)
                        out["insertedSystemText"] = true
                        answer(out)
                    }
                    return
                }
                guard let press = request["press"] as? String else { answer(out); return }
                var rows = menu?.items ?? []
                var row: NSMenuItem?
                for title in press.split(separator: "/").map(String.init) {
                    row = rows.first { $0.title == title }
                    rows = row?.submenu?.items ?? []
                }
                guard let row, let owner = row.menu else { out["pressed"] = false; answer(out); return }
                // Once the menu has closed, as after a click on the row.
                DispatchQueue.main.async {
                    owner.performActionForItem(at: owner.index(of: row))
                    out["pressed"] = true
                    answer(out)
                }
            }
        }
        Self.pageMenuWatch = watch
        RunLoop.main.add(watch, forMode: .common)
    }

    /// Test-world pictures of a native menu a Settings face opens (a
    /// DropAnchor by "title", such as Gemini's ···): its rows, "path" for
    /// a picture of it over the window, and "press" for a row chosen once
    /// it has closed, as a click would. The menu tracks in a loop of its
    /// own, so the watch runs in the common modes and nothing waits on it.
    func anchorMenuCommand(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "anchor-menu only works on a --test run"]); return }
        guard let title = request["title"] as? String else { answer(["error": "no title"]); return }
        func find(_ view: NSView) -> DropAnchor.Anchor? {
            if let anchor = view as? DropAnchor.Anchor, anchor.title == title { return anchor }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let face = NSApp.windows.lazy.compactMap({ ($0.contentView?.superview ?? $0.contentView).flatMap(find) }).first
        let native = title == "Shortcut filters" ? SettingsWindow.shared.shortcutFilterButton : nil
        guard let window = face?.window ?? native?.window
        else { answer(["error": "no menu titled \(title)"]); return }
        Self.pageMenuWatch?.invalidate()
        Self.pageMenu = nil
        if let seen = Self.pageMenuSeen { NotificationCenter.default.removeObserver(seen) }
        Self.pageMenuSeen = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                if Self.pageMenu == nil, let menu = note.object as? NSMenu, menu != NSApp.mainMenu { Self.pageMenu = menu }
            }
        }
        window.makeKeyAndOrderFront(nil)
        if let face { face.press() }
        else if let native { DispatchQueue.main.async { native.performClick(nil) } }
        let started = CACurrentMediaTime()
        let watch = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let menus = Self.menuWindows()
                let now = CACurrentMediaTime()
                guard !menus.isEmpty, now - started > 0.5 else {
                    if now - started > 6 { timer.invalidate(); answer(["error": "no menu opened"]) }
                    return
                }
                timer.invalidate()
                var out: [String: Any] = ["menus": menus.count]
                let menu = Self.pageMenu
                if let menu { out["items"] = Self.rows(menu) }
                if let red = menu?.items.first(where: { $0.attributedTitle != nil }) {
                    out["colored"] = red.title
                }
                if let path = request["path"] as? String { out["saved"] = Self.picture(menus, over: window, to: path) }
                menu?.cancelTracking()
                Self.pageMenu = nil
                guard let press = request["press"] as? String else { answer(out); return }
                guard let menu, let index = menu.items.firstIndex(where: { $0.title == press }) else {
                    out["pressed"] = false; answer(out); return
                }
                DispatchQueue.main.async {
                    menu.performActionForItem(at: index)
                    out["pressed"] = true
                    answer(out)
                }
            }
        }
        Self.pageMenuWatch = watch
        RunLoop.main.add(watch, forMode: .common)
    }

    /// A key typed into the open menu, through the app's own queue: nothing
    /// is posted to the system.
    private static func press(_ characters: String, code: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: 0, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// The rows, a submenu's under its row.
    static func rows(_ menu: NSMenu) -> [[String: Any]] {
        menu.items.filter { !$0.isSeparatorItem }.map { item in
            var row: [String: Any] = ["title": item.title, "enabled": item.isEnabled, "on": item.state == .on]
            // Whose row it is: WebKit's id, and who answers a press on it.
            if let id = item.identifier?.rawValue { row["id"] = id }
            if let action = item.action { row["action"] = NSStringFromSelector(action) }
            if let target = item.target { row["target"] = String(describing: type(of: target)) }
            // Whether the line wears a picture, and the tip the system would draw over it.
            row["image"] = item.image != nil
            // Which picture: a system symbol says its name here.
            if let image = item.image { row["picture"] = String(describing: image) }
            if let tip = item.toolTip { row["tip"] = tip }
            if let sub = item.submenu { row["submenu"] = rows(sub) }
            return row
        }
    }

    /// This app's menu windows on screen, front first, in the window
    /// server's coordinates.
    static func menuWindows() -> [(id: CGWindowID, bounds: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? Int == me,
                  (info[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow)),
                  let id = info[kCGWindowNumber as String] as? Int,
                  let box = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: box as CFDictionary)
            else { return nil }
            return (CGWindowID(id), bounds)
        }
    }

    /// The menus and the window under them, cut to the menus and a margin.
    static func picture(_ menus: [(id: CGWindowID, bounds: CGRect)], over window: NSWindow, to path: String) -> String {
        typealias Grab = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        let area = menus.map { $0.bounds }.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -28, dy: -28)
        var ids = menus.map { UnsafeRawPointer(bitPattern: UInt($0.id)) }
        ids.append(UnsafeRawPointer(bitPattern: UInt(window.windowNumber)))
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"),
              let image = unsafeBitCast(symbol, to: Grab.self)(area, array, 1 << 3)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil
        else { return "" }
        return path
    }
}
