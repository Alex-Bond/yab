import AppKit
import Testing
@testable import Fast

extension QuestionKeysTests {
    @MainActor @Suite(.serialized)
    struct SidebarToggleKeysTests {
        @Test(arguments: [false, true])
        func repeatsAreConsumedWithoutStartingAnotherTransition(remapped: Bool) async throws {
            _ = NSApplication.shared
            let map = Keymap.shared, saved = map.chosen[Shortcut.Action.column.rawValue]
            let system = Hotkeys.userKeys()
            let settings = ["sidebar", "sidebar.shut", "strip.shut"]
            let old = settings.map { Store.settings.object(forKey: $0) }
            let id = UUID(), browser = Browser(windowID: id)
            map.take(system: [:])
            map.reset(.column)
            if remapped { map.set(Hotkey("h", [.control, .option, .command]), for: .column) }
            defer {
                if let saved { map.set(Hotkey(stored: saved), for: .column) } else { map.reset(.column) }
                map.take(system: system)
                for (key, value) in zip(settings, old) { Store.settings.set(value, forKey: key) }
                browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
                browser.tabs.forEach { $0.close() }
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
            let view = ContentView(browser: browser)
            func press(repeated: Bool) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: remapped ? [.control, .option, .command] : .command,
                    timestamp: 0, windowNumber: 0, context: nil,
                    characters: remapped ? "h" : "s", charactersIgnoringModifiers: remapped ? "h" : "s",
                    isARepeat: repeated, keyCode: remapped ? 4 : 1))
            }
            browser.prefs.sidebar = true
            for shut in [false, true] {
                browser.prefs.sideShut = shut
                for _ in 0..<20 {
                    #expect(view.take(try press(repeated: true)))
                    #expect(!browser.folding, "Every repeat is consumed before the transition starts")
                    #expect(browser.prefs.sideShut == shut)
                }
            }
            browser.prefs.sideShut = false
            #expect(view.take(try press(repeated: false)))
            #expect(browser.folding, "A fresh down still starts the transition")
            for _ in 0..<21 { #expect(view.take(try press(repeated: true))) }
            _ = try await Loaded.until(2) { browser.prefs.sideShut }
            #expect(browser.prefs.sideShut, "Repeats must not reverse the first down's requested state")
            // Let the transition's completion release its captured browser.
            try await Task.sleep(for: .milliseconds(700))
        }
    }
}
