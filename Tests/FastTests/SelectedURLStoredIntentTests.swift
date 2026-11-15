import AppKit
import Testing
import WebKit
@testable import Fast

/// Separate stored-menu-open metadata qualification, main-compatible at 66e27b85.
/// This does not replace SelectedURLFocusTests or prove physical Cmd-click.
/// The real DOM reader and menu target/action reach Fast.Tab and Browser.open.
@MainActor @Suite(.serialized)
struct SelectedURLStoredIntentTests {
    enum Input: String, CaseIterable, Sendable {
        case plain, command, shiftCommand
        var flags: NSEvent.ModifierFlags {
            switch self {
            case .plain: []
            case .command: .command
            case .shiftCommand: [.command, .shift]
            }
        }
        var foreground: Bool { self != .command }
    }

    /// Transparent instrumentation: same URL and exact original arguments.
    /// BASE has one argument; the candidate transports native modifier metadata.
    private func observing<A>(_ original: @escaping (A) -> Void,
                              _ seen: @escaping (Int, NSEvent.ModifierFlags?) -> Void) -> (A) -> Void {
        { a in seen(1, nil); original(a) }
    }

    private func observing<A, B>(_ original: @escaping (A, B) -> Void,
                                 _ seen: @escaping (Int, NSEvent.ModifierFlags?) -> Void) -> (A, B) -> Void {
        { a, b in seen(2, b as? NSEvent.ModifierFlags); original(a, b) }
    }

    private func marker(_ name: String, _ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            print("1210_STORED_HARNESS_UNSUPPORTED: could not serialize receipt")
            return
        }
        print(name + ":" + text)
    }

    private func eventSnapshot(_ event: NSEvent?) -> [String: Any] {
        guard let event else { return ["present": false] }
        return ["present": true, "type": event.type.rawValue, "window": event.windowNumber,
                "timestamp": event.timestamp, "flags": event.modifierFlags.rawValue]
    }

    private enum Failure: Error { case documentNotReady, noAddedTab }

    private func ready(_ tab: Fast.Tab, title: String) async throws {
        for _ in 0..<200 {
            if !requireNativeWebKitFixture(tab, "SelectedURLStoredIntentTests").isLoading,
               (try? await requireNativeWebKitFixture(tab, "SelectedURLStoredIntentTests").evaluateJavaScript("document.title")) as? String == title { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.documentNotReady
    }

    private func fixture(shy: Bool, _ check: (Browser, Fast.Tab, Fast.Tab) async throws -> Void) async throws {
        _ = NSApplication.shared
        try #require(Store.testing && Store.unitTests, "own unit-test profile is required")
        let window = UUID(), browser = Browser(windowID: window)
        defer {
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
        }
        let source = Fast.Tab(shy: shy, factory: .webKitOnly)
        browser.prepare(source)
        browser.lay(browser.tabs + [source])
        browser.select(source)
        source.go(to: URL(string: "about:blank")!)
        requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").seenOffscreen = true
        requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").configuration.preferences.inactiveSchedulingPolicy = .none
        requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").loadHTMLString("<title>Selected URL source</title><p id='words'>destination.invalid/selected</p><p id='sentinel'>source retained</p>",
                                 baseURL: URL(string: "http://127.0.0.1:9/selected-source"))
        try await ready(source, title: "Selected URL source")
        let neighbor = Fast.Tab(shy: shy)
        browser.prepare(neighbor)
        neighbor.restore(url: URL(string: "https://sleeping-neighbor.invalid/")!, title: "Sleeping neighbor")
        browser.lay(browser.tabs + [neighbor])
        browser.select(source)
        browser.editing = true
        try #require(browser.activeID == source.id && source.shy == shy)
        try #require(neighbor.asleep && neighbor.builtPage == nil)
        try await check(browser, source, neighbor)
    }

    private func menu(source: Fast.Tab, flags: NSEvent.ModifierFlags) async throws -> (NSMenu, NSEvent, Int) {
        let selected = try await requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").evaluateJavaScript("""
        (() => {const r=document.createRange();r.selectNodeContents(document.getElementById('words'));
        const s=getSelection();s.removeAllRanges();s.addRange(r);return String(s)})()
        """)
        try #require(selected as? String == "destination.invalid/selected")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let anchor = NSMenuItem(title: "Search", action: nil, keyEquivalent: "")
        anchor.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")
        menu.addItem(anchor)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").readBeforeMenu(menu) { _ in done.resume() }
        }
        // This is the actual existing native menu-open receipt. No KVC,
        // selector replacement or new production test API is used.
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").willOpenMenu(menu, with: event)
        let index = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "YabGoToSelectedURL" })
        try #require(menu.items[index].target === requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests"))
        try #require(menu.items[index].action == NSSelectorFromString("goToSelection:"))
        try #require(menu.items[index].isEnabled)
        return (menu, event, index)
    }

    private func choose(_ menu: NSMenu, event: NSEvent, index: Int, source: Fast.Tab,
                        input: Input, shy: Bool) throws {
        var calls = 0, neutral = false, observedArity = 0
        var forwarded: NSEvent.ModifierFlags?, observedAmbient: NSEvent.ModifierFlags = []
        let routing: NSEvent.ModifierFlags = [.command, .shift]
        let original = try #require(requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").onSelectedURL)
        requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").onSelectedURL = observing(original) { arity, transported in
            calls += 1
            observedArity = arity
            forwarded = transported
            let current = NSApp.currentEvent
            let global = NSEvent.modifierFlags
            let ambient = current?.modifierFlags ?? global
            observedAmbient = ambient
            neutral = ambient.intersection(routing).isEmpty && global.intersection(routing).isEmpty
            var receipt: [String: Any] = ["scope": "storedMenuOpen", "input": input.rawValue,
                "shy": shy, "call": calls, "arity": arity, "requestedFlags": event.modifierFlags.rawValue,
                "current": self.eventSnapshot(current), "globalFlags": global.rawValue,
                "effectiveAmbientFlags": ambient.rawValue, "ambientNeutral": neutral]
            if let transported { receipt["forwardedFlags"] = transported.rawValue }
            else { receipt["forwardedFlags"] = NSNull() }
            self.marker("1210_STORED_CALLBACK", receipt)
        }
        defer { requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").onSelectedURL = original }
        // This observes stored context-open metadata. It deliberately does
        // not synthesize, set or claim a selection-time currentEvent.
        requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").didCloseMenu(menu, with: event)
        menu.performActionForItem(at: index)
        if calls != 1 || !neutral {
            print("1210_STORED_HARNESS_UNSUPPORTED: actual callback must run once with neutral ambient Cmd/Shift; calls=\(calls)")
        }
        try #require(calls == 1 && neutral, "stored metadata qualification requires the actual callback and neutral ambient input")
        if observedArity == 2 {
            #expect(forwarded == event.modifierFlags.union(observedAmbient), "1210_STORED transparent modifier metadata transport")
        }
    }

    @Test(arguments: Input.allCases)
    func storedMenuOpenModifiersReachRealGoToAction(input: Input) async throws {
        for shy in [false, true] { try await fixture(shy: shy) { browser, source, neighbor in
            let sourceID = source.id, neighborID = neighbor.id
            let sourceURL = source.address, sourceStore = source.store
            let (menu, event, index) = try await menu(source: source, flags: input.flags)
            try choose(menu, event: event, index: index, source: source, input: input, shy: shy)
            let destination = try #require(browser.tabs.first { $0 !== source && $0 !== neighbor })
            // Catch a delayed fronting callback as well as synchronous focus.
            try await Task.sleep(for: .milliseconds(450))
            let observedForeground = browser.activeID == destination.id
            marker("1210_STORED_GO_TO", ["scope": "storedMenuOpen", "input": input.rawValue,
                "shy": shy, "foreground": observedForeground, "tabs": browser.tabs.count])
            #expect(observedForeground == input.foreground, "1210_STORED_FOCUS foreground input=\(input.rawValue) shy=\(shy)")
            #expect(browser.activeID == (input.foreground ? destination.id : sourceID), "1210_STORED_FOCUS active input=\(input.rawValue) shy=\(shy)")
            #expect(browser.editing == !input.foreground, "1210_STORED_FOCUS editing input=\(input.rawValue) shy=\(shy)")
            #expect(destination.address?.absoluteString == "https://destination.invalid/selected")
            #expect(destination.from == sourceID)
            #expect(destination.shy == shy)
            if shy { #expect(destination.store === sourceStore) }
            #expect(source.address == sourceURL)
            #expect(browser.tabs.contains { $0.id == neighborID && $0 === neighbor })
            #expect(browser.tabs.count == 3)
            #expect(neighbor.asleep && neighbor.builtPage == nil, "the background neighbor must not wake")
            #expect(try await requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").evaluateJavaScript("document.getElementById('sentinel').textContent") as? String == "source retained")
        } }
    }

    @Test func staleStoredMenuCannotOpenAfterSourceNavigation() async throws {
        try await fixture(shy: true) { browser, source, _ in
            let (menu, event, index) = try await menu(source: source, flags: .command)
            let active = browser.activeID, count = browser.tabs.count
            requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").loadHTMLString("<title>Replacement document</title>", baseURL: URL(string: "http://127.0.0.1:9/replaced-source"))
            try await ready(source, title: "Replacement document")
            requireNativeWebKitFixture(source, "SelectedURLStoredIntentTests").didCloseMenu(menu, with: event)
            menu.performActionForItem(at: index)
            try await Task.sleep(for: .milliseconds(100))
            #expect(browser.tabs.count == count)
            #expect(browser.activeID == active)
        }
    }
}
