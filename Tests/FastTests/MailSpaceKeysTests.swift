import AppKit
import Testing
@testable import Fast

/// ⌃1 to ⌃9 out of Mail with spaces off (feedback #1657): the foot shows
/// the one space and Mail beside it, with ⌃1 and ⌃2 on them, and two
/// fingers go between them; the keys went nowhere, keyed on spaces being on.
@MainActor
@Suite(.serialized)
struct MailSpaceKeysTests {
    private func fixture(spaces: Bool, _ body: (Browser, ContentView, NSWindow) throws -> Void) rethrows {
        _ = NSApplication.shared
        let keys = ["mail", MailExperiment.key, "sidebar", "mail.pin.asked"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        Store.settings.set(true, forKey: "mail")
        Store.settings.set(true, forKey: MailExperiment.key)
        Store.settings.set(false, forKey: "mail.pin.asked")
        let id = UUID(), browser = Browser(windowID: id)
        let usedSpaces = browser.prefs.usesSpaces
        let back = MailSpaceState.shared.back
        let turned = MailSpaceState.shared.turnedSidebar
        let split = MailList.shared.split
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            if browser.inMail { browser.leaveMail() }
            browser.prefs.usesSpaces = usedSpaces
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            for suffix in ["", "-\(Space.mailID.uuidString)"] {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)\(suffix).json"))
            }
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            MailSpaceState.shared.back = back
            MailSpaceState.shared.turnedSidebar = turned
            MailList.shared.split = split
            for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) }
        }
        browser.prefs.usesSpaces = spaces
        browser.editing = false
        try body(browser, ContentView(browser: browser), window)
    }

    private func control(_ digit: Int, in window: NSWindow) throws -> NSEvent {
        let codes: [Int: UInt16] = [1: 18, 2: 19]
        let code = try #require(codes[digit])
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             characters: "\(digit)", charactersIgnoringModifiers: "\(digit)",
                                             isARepeat: false, keyCode: code))
    }

    @Test(arguments: [false, true])
    func controlOneLeavesMailForTheFirstSpace(spaces: Bool) throws {
        try fixture(spaces: spaces) { browser, view, window in
            let first = browser.turnOrder.first { $0.id != Space.mailID }?.id
            browser.enterMail()
            try #require(browser.inMail)
            // The Archive list, as in the report.
            MailList.shared.split = "older"
            #expect(view.take(try control(1, in: window)))
            #expect(!browser.inMail)
            #expect(browser.spaceID == first)
        }
    }
}
