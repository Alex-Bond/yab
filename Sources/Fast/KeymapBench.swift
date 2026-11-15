import AppKit
import Carbon.HIToolbox

// The bench's words for Settings › Shortcuts: what each key is now, in the
// keymap and in the menus as drawn; a row's recorder started and keys
// pressed into it as the keyboard sends them; the ASCII layout's reading of
// a key beside another layout's; and what a change and the filter cost the
// main thread.

extension Bench {
    /// Keys the browser window was sent on a --test run, how they were
    /// read and what they are in each place, for `keys heard`: a key
    /// pressed on the real keyboard with some layout picked.
    @MainActor static var presses: [[String: Any]] = []

    @MainActor static func heard(_ event: NSEvent) {
        let readings = Hotkey.readings(event)
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let layout = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        presses.append([
            "code": Int(event.keyCode), "characters": event.characters ?? "",
            "ignoring": event.charactersIgnoringModifiers ?? "", "layout": layout,
            "readings": readings.map(\.text),
            "actions": Shortcut.Action.allCases.filter { Keymap.shared.matches(event, $0) }.map(\.rawValue),
        ])
        if presses.count > 50 { presses.removeFirst(presses.count - 50) }
    }

    func keysCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let keymap = Keymap.shared
        let action = (request["action"] as? String).flatMap(Shortcut.Action.init)

        func state() -> [String: Any] {
            [
                "keys": Shortcut.Action.allCases.map { "\($0.rawValue)=\(keymap.text($0))\(keymap.isDefault($0) ? "" : " (chosen)")" },
                // Unless asked not to: reading the menus brings them up to date.
                "menu": request["quiet"] as? Bool == true ? [] : Self.menuKeys(),
                "editingMenu": Self.editingMenuState(),
                "textUndo": (NSApp.keyWindow?.firstResponder as? NSTextView).map {
                    ["canUndo": $0.undoManager?.canUndo ?? false, "canRedo": $0.undoManager?.canRedo ?? false]
                } ?? [:],
                "said": keymap.said,
                // What an alias typed in Settings › Search came to last.
                "site": SiteEditing.shared.said,
                "recording": keymap.recording,
                "stored": Store.settings.dictionary(forKey: "shortcuts") ?? [:],
                // Mail's groups as Settings › Shortcuts lists them, its keys
                // and the words' marks (as ? lists them): what each does and
                // its keys now, a keystroke at a time.
                "mail": Shortcut.all.filter({ $0.title == "Mail" || $0.title == "Mail Formatting" }).flatMap(\.items).map { item -> [String] in
                    let caps = item.action.map { keymap.keys($0).map { [$0.caps] } ?? [] } ?? item.fixed
                    return [item.does, caps.map { $0.joined() }.joined(separator: " ")]
                },
            ]
        }
        /// After the menus have been built again, a pass or two on.
        func later(_ seconds: Double = 0.3) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { answer(state()) }
        }

        switch request["act"] as? String ?? "list" {
        case "list":
            answer(state())

        case "toolbar":
            guard Store.testing else { answer(["error": "toolbar only works on a --test run"]); return }
            answer(SettingsWindow.shared.shortcutToolbarState)

        case "search":
            // The search glass pressed, and how it stands a beat later:
            // an empty field that lost the keys has gone back to the glass.
            guard Store.testing else { answer(["error": "search only works on a --test run"]); return }
            _ = SettingsWindow.shared.beginShortcutSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                answer(SettingsWindow.shared.shortcutToolbarState)
            }

        case "filters":
            // The filter button pressed as a click presses it, then the list
            // it opens (DropPopup's bench answer); "tick" names boxes to toggle.
            guard Store.testing, let button = SettingsWindow.shared.shortcutFilterButton
            else { answer(["error": "filters only works on a --test run with Shortcuts open"]); return }
            DispatchQueue.main.async { button.performClick(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                var drop = request
                drop.removeValue(forKey: "title")
                _ = DropPopup.bench(drop)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(DropPopup.bench([:])) }
            }

        case "set", "remove", "reset":
            guard let action else { answer(["error": "which action? one of " + Shortcut.Action.allCases.map(\.rawValue).joined(separator: " ")]); return }
            switch request["act"] as? String {
            case "set":
                guard let (flags, name, _) = Self.chord(request["keys"] as? String ?? ""), !name.isEmpty
                else { answer(["error": "keys like opt+cmd+y"]); return }
                keymap.set(Hotkey(name, flags), for: action)
            case "remove": keymap.set(nil, for: action)
            default: keymap.reset(action)
            }
            later()

        case "record":
            // Settings on Shortcuts, the row brought into view, and its
            // recorder listening, as a click on it would leave it.
            guard Store.testing else { answer(["error": "record only works on a --test run"]); return }
            guard let action else { answer(["error": "which action?"]); return }
            browser.tuning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SettingsWindow.shared.bench(key: action)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    keymap.slot(action).asked = true
                    later(0.5)
                }
            }

        case "point":
            // A row drawn as if the pointer were on it, or none.
            for each in Shortcut.Action.allCases { keymap.slot(each).pointed = each == action }
            SiteEditing.shared.pointed = request["site"] as? String
            later(0.2)

        case "eager":
            // A recorder in every Hotkey cell and a field in every site's
            // alias, as before they waited for the pointer, to measure
            // against. Takes effect as Settings opens.
            guard Store.testing else { answer(["error": "eager only works on a --test run"]); return }
            ShortcutRecorder.eager = request["on"] as? Bool ?? true
            answer(["eager": ShortcutRecorder.eager])

        case "hold":
            // The green and red of a cell kept lit this long, for pictures.
            Glow.hold = request["seconds"] as? Double ?? 0.14
            answer(["hold": Glow.hold])

        case "alias":
            // Settings › Search, one site's alias field given the keys, to
            // be typed into with press: letters, then return.
            guard Store.testing else { answer(["error": "alias only works on a --test run"]); return }
            guard let host = request["site"] as? String else { answer(["error": "which site? site:youtube.com"]); return }
            browser.openSettings(.search)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindow.shared.bench(page: .search)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    SiteEditing.shared.typing = host
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        answer(["typing": SiteEditing.shared.typing ?? "", "said": SiteEditing.shared.said])
                    }
                }
            }

        case "press":
            // Keys as the keyboard sends them, into Settings: the recorder's
            // monitor sees them first, as it would a hand's. "opt+cmd+y",
            // or "opt+cmd+y@н" for the same key on a non-Latin layout.
            guard Store.testing else { answer(["error": "press only works on a --test run"]); return }
            guard let (flags, name, typed) = Self.chord(request["keys"] as? String ?? "") else { answer(["error": "keys like opt+cmd+y"]); return }
            // "browser": to the browser's window instead, queued as the
            // keyboard's own are, the app's key watchers and menus first.
            if request["browser"] as? Bool == true {
                Self.send(flags, name, typed, to: BrowserWindows.shared.window(for: browser) ?? Links.window, queued: true, native: true)
            } else {
                Self.send(flags, name, typed, to: SettingsWindow.shared.window ?? Links.window)
            }
            later(0.1)

        case "layout":
            // What the key under T and the rest type on the layout in use,
            // on the ASCII-capable one the keys are read with, and on the
            // non-Latin one (Russian), read from the system without switching to it.
            let codes: [UInt16] = [17, 16, 13, 35, 33, 30, 43, 47, 0, 8]
            let ascii = KeyLayout.build(from: nil)
            let russian = KeyLayout.source("com.apple.keylayout.Russian").map { KeyLayout.build(from: $0) } ?? [:]
            let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            func id(_ source: TISInputSource) -> String {
                guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
                return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            }
            answer([
                "current": id(current), "ascii": id(asciiSource),
                "keys": codes.map { "\($0): read as \(KeyLayout.key($0) ?? "-"), ascii \(ascii[$0] ?? "-"), russian \(russian[$0] ?? "-")" },
            ])

        case "cost":
            // A keystroke looked up the way the key monitor looks it up,
            // many times over: what each costs.
            let count = 100_000
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40
            ) else { answer(["error": "no event"]); return }
            let t0 = CACurrentMediaTime()
            var found = 0
            for _ in 0..<count {
                if let hotkey = Hotkey(event), keymap.action(for: hotkey) != nil { found += 1 }
            }
            let each = (CACurrentMediaTime() - t0) / Double(count) * 1e9
            // And the table itself, read once per layout, at the first key.
            let t1 = CACurrentMediaTime()
            _ = KeyLayout.build(from: nil)
            let build = (CACurrentMediaTime() - t1) * 1000
            answer(["ns_per_lookup": (each * 10).rounded() / 10, "found": found, "layout_build_ms": (build * 100).rounded() / 100])

        case "rebuild":
            // History's key changed back and forth, each change timed on the
            // main thread until it next goes idle, the menus built again
            // included, and for the tenth of a second after.
            let count = request["count"] as? Int ?? 12
            let other = Hotkey("y", [.option, .command])
            var first: [Double] = []
            var cpu: [Double] = []
            var busy: [Double] = []
            func step(_ i: Int) {
                guard i < count else {
                    keymap.reset(.history)
                    answer([
                        "pass_ms": first.map { ($0 * 100).rounded() / 100 },
                        "busy_100ms": busy.map { ($0 * 100).rounded() / 100 },
                        "median_pass_ms": Self.median(first), "median_cpu_ms": Self.median(cpu),
                        "median_busy_ms": Self.median(busy),
                        "menu": Self.menuKeys().filter { $0.hasPrefix("History") },
                    ])
                    return
                }
                let t0 = CACurrentMediaTime()
                let c0 = Self.mainCPU()
                let meter = Busy()
                keymap.set(i % 2 == 0 ? other : nil, for: .history)
                Self.whenIdle { first.append((CACurrentMediaTime() - t0) * 1000) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    cpu.append(Self.mainCPU() - c0)
                    busy.append(meter.stop())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step(i + 1) }
                }
            }
            step(0)

        case "filter":
            // Words typed into the page's filter a key at a time, a tenth of
            // a second apart, then taken back with ⌫: each keystroke timed
            // until the main thread goes idle, and its CPU over the tenth of
            // a second after. Settings must be open on Shortcuts.
            guard Store.testing else { answer(["error": "filter only works on a --test run"]); return }
            let native = SettingsWindow.shared.beginShortcutSearch()
            guard let window = SettingsWindow.shared.window, let field = native ?? Self.field("Search by name or alias", in: window.contentView?.superview) ?? Self.field("Filter", in: window.contentView)
            else { answer(["error": "no filter field: open Settings on Shortcuts first"]); return }
            if native == nil { window.makeFirstResponder(field) }
            let text = Array(request["text"] as? String ?? "reload")
            // "keep": left typed, for a picture of the page filtered.
            let back = request["keep"] as? Bool == true ? [] : text.map { _ in ("⌫", "\u{7f}") }
            let presses: [(String, String)] = text.map { (String($0), String($0)) } + back
            var first: [Double] = []
            var cpu: [Double] = []
            var busy: [Double] = []
            func step(_ i: Int) {
                guard i < presses.count else {
                    answer([
                        "keys": presses.map(\.0).joined(),
                        "pass_ms": first.map { ($0 * 100).rounded() / 100 },
                        "busy_100ms": busy.map { ($0 * 100).rounded() / 100 },
                        "median_busy_ms": Self.median(busy),
                        "worst_busy_ms": ((busy.max() ?? 0) * 100).rounded() / 100,
                        "median_pass_ms": Self.median(first), "worst_pass_ms": ((first.max() ?? 0) * 100).rounded() / 100,
                        "median_cpu_ms": Self.median(cpu),
                    ])
                    return
                }
                let (name, chars) = presses[i]
                let t0 = CACurrentMediaTime()
                let c0 = Self.mainCPU()
                let meter = Busy()
                let code = name == "⌫" ? 51 : KeyLayout.code(for: name) ?? 49
                Self.post(window, code: code, chars: chars, flags: [])
                Self.whenIdle { first.append((CACurrentMediaTime() - t0) * 1000) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    cpu.append(Self.mainCPU() - c0)
                    busy.append(meter.stop())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step(i + 1) }
                }
            }
            let deadline = CACurrentMediaTime() + 2
            func ready() {
                guard field.window === window, field.currentEditor() != nil else {
                    guard CACurrentMediaTime() < deadline else {
                        answer(["error": "native search did not receive keyboard focus"])
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { ready() }
                    return
                }
                // Clear only after the real search has attached and focused,
                // just as keys following a click on the magnifier would.
                if request["keep"] as? Bool == true {
                    Self.post(window, code: 0, chars: "a", flags: .command)
                    Self.post(window, code: 51, chars: "\u{7f}", flags: [])
                }
                step(0)
            }
            ready()

        case "heard":
            // What the browser window heard since last asked (Bench.heard),
            // and where it is now: tabs, the one in front, the field, and
            // how many pages have come in from the side so far.
            answer([
                "presses": Self.presses, "tabs": browser.tabs.count,
                "active": browser.active.flatMap { tab in browser.tabs.firstIndex { $0 === tab } } ?? -1,
                "address": browser.active?.address?.absoluteString ?? "", "field": browser.fieldShowing,
                "settings": browser.tuning, "key": NSApp.keyWindow.map { "\(type(of: $0))" } ?? "",
                "arrivals": Tab.arrivals,
            ])
            Self.presses = []

        case "front":
            // Settings put away and the browser's window made key, for keys
            // pressed on the real keyboard next.
            browser.tuning = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.activate(ignoringOtherApps: true)
                BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
                Self.presses = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    answer(["key": NSApp.keyWindow.map { "\(type(of: $0))" } ?? "", "active": NSApp.isActive])
                }
            }

        default:
            answer(["error": "keys list|set ACTION KEYS|remove ACTION|reset ACTION|record ACTION|press KEYS|layout|cost|rebuild|filter TEXT|heard|front"])
        }
    }

    /// "opt+cmd+y@н": the modifiers, the key as the ASCII layout names it,
    /// and what the layout in use types for it, when that isn't the key.
    static func chord(_ text: String) -> (NSEvent.ModifierFlags, String, String?)? {
        let (keys, typed): (Substring, String?) = text.firstIndex(of: "@").map { (text[..<$0], String(text[text.index(after: $0)...])) } ?? (Substring(text), nil)
        var flags: NSEvent.ModifierFlags = []
        var name = ""
        for part in keys.lowercased().split(separator: "+") {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            case "fn": flags.insert(.function)
            case "escape": name = "esc"
            case "tab": name = "⇥"
            case "left": name = "←"
            case "right": name = "→"
            case "down": name = "↓"
            case "up": name = "↑"
            case "return", "enter": name = "↩"
            case "delete": name = "⌫"
            default: name = String(part)
            }
        }
        return (flags, name, typed)
    }

    /// The key down and up, through the app, the way the keyboard sends
    /// them: key monitors first, then the window and its menus. `queued`:
    /// into the app's event queue for its window, as the keyboard's own
    /// arrive, rather than handed over at once, which a probe that isn't the
    /// active app doesn't always take (a menu's key, ⇧⌘I); it never
    /// activates the app. `straight`: to the window itself, for its first
    /// responder, where a probe that isn't the active app has no key
    /// window to send a letter to; the app's key monitors are passed by.
    static func send(_ flags: NSEvent.ModifierFlags, _ name: String, _ typed: String?, to window: NSWindow?, code: UInt16? = nil,
                     queued: Bool = false, straight: Bool = false, native: Bool = false, layout: Bool = false) {
        let code = code ?? KeyLayout.code(for: name) ?? Bench.keyCode(for: Character(name.isEmpty ? " " : String(name.prefix(1))))
        let plain: [String: String] = ["esc": "\u{1b}", "⇥": "\t", "↩": "\r", "⌫": "\u{7f}", "space": " ",
                                       "←": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "→": String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                       "↓": String(UnicodeScalar(NSDownArrowFunctionKey)!), "↑": String(UnicodeScalar(NSUpArrowFunctionKey)!)]
        // AppKit's menu matching reads the shifted characters too: sending
        // lowercase z with Shift can invoke Undo instead of Redo. An explicit
        // layout character remains exactly what the caller supplied.
        let chars = typed ?? plain[name] ?? (flags.contains(.shift) ? name.uppercased() : name)
        post(window, code: code, chars: chars, flags: flags, queued: queued, straight: straight, native: native,
             unicode: layout ? nil : typed)
    }

    static func post(_ window: NSWindow?, code: UInt16, chars: String, flags: NSEvent.ModifierFlags, queued: Bool = false,
                     straight: Bool = false, native: Bool = false, unicode: String? = nil) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            // Quartz retains the keyboard metadata AppKit needs for menu
            // items that spell Shift separately from their lowercase key.
            // Deliver inside this app, without relying on system event
            // injection permissions. These menu events use the key window.
            if native, let key = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown) {
                key.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
                // What the layout picked types on the key, as a hand's
                // press, unless the caller said what it types ("@е").
                if let unicode {
                    let units = Array(unicode.utf16)
                    key.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                }
                if let event = NSEvent(cgEvent: key) {
                    // Queued for a window, it goes there though the app isn't
                    // in front, with the characters Quartz gave it.
                    if queued, let window, let aimed = NSEvent.keyEvent(
                        with: event.type, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: event.characters ?? chars, charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? chars,
                        isARepeat: false, keyCode: code
                    ) { NSApp.postEvent(aimed, atStart: false) }
                    else if queued { NSApp.postEvent(event, atStart: false) }
                    else if straight, let window { window.sendEvent(event) }
                    else { NSApp.sendEvent(event) }
                }
                continue
            }
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            ) else { continue }
            if queued {
                NSApp.postEvent(event, atStart: false)
            } else if straight, let window {
                window.sendEvent(event)
            } else {
                NSApp.sendEvent(event)
            }
        }
    }

    /// Native editing actions and their current validation, for key probes.
    static func editingMenuState() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard let action = item.action,
                      NSStringFromSelector(action).lowercased().contains("undo") ||
                      NSStringFromSelector(action).lowercased().contains("redo") ||
                      item.title.hasPrefix("Undo") || item.title.hasPrefix("Redo") else { continue }
                rows.append(["title": item.title, "enabled": item.isEnabled,
                             "action": NSStringFromSelector(action), "key": item.keyEquivalent,
                             "flags": item.keyEquivalentModifierMask.rawValue,
                             "target": item.target.map { String(describing: type(of: $0)) } ?? "responder chain"])
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
        return rows
    }

    /// Every menu item that has a key, "History › Show History ⌘Y".
    static func menuKeys() -> [String] {
        var out: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            // As AppKit asks before it opens a menu or looks in it for a
            // key: SwiftUI brings its items up to date then.
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items {
                if let sub = item.submenu { walk(sub, item.title) }
                guard !item.keyEquivalent.isEmpty else { continue }
                var key = item.keyEquivalent
                var mask = item.keyEquivalentModifierMask
                if key.count == 1, key != key.lowercased() {
                    key = key.lowercased()
                    mask.insert(.shift)
                }
                out.append("\(path) › \(item.title) \(Hotkey.caps(key, mask).joined())")
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, "") }
        return out.map { $0.hasPrefix(" › ") ? String($0.dropFirst(3)) : $0 }
    }

    /// The first text field whose prompt is `placeholder`.
    static func field(_ placeholder: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder || field.placeholderAttributedString?.string == placeholder {
            return field
        }
        for sub in view.subviews { if let found = field(placeholder, in: sub) { return found } }
        return nil
    }

    /// Once the main run loop has done this pass, drawing committed, and is
    /// about to wait.
    static func whenIdle(_ done: @escaping () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { _, _ in done() }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return (sorted[sorted.count / 2] * 100).rounded() / 100
    }
}
