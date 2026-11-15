import AppKit
import Foundation
import Testing
@testable import Fast

/// Register 987 (#608): ⌘L's field over a small window wears that
/// window's site icon, not the main window's active tab's.
@MainActor
@Suite(.serialized)
struct LinkWindowOwnPageTests {
    @Test func fieldOverTheSmallWindowIsItsPage() {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        defer {
            browser.letGo()
            if let window = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            }
        }
        let main = Tab(later: Store.websites)
        main.restore(url: URL(string: "https://main987.test/")!, title: "Main")
        browser.prepare(main)
        browser.lay([main])
        browser.activeID = main.id
        let guest = Tab(later: Store.websites)
        let guestURL = URL(string: "https://guest987.test/page")!
        guest.restore(url: guestURL, title: "Guest")
        browser.prepare(guest)
        browser.outside.append(guest)
        let shell = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 400, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        defer { shell.close() }

        browser.edit()
        #expect(browser.fieldPage === main, "the main window's field is over its tab")
        browser.dismiss()

        browser.edit(over: guest, in: shell)
        #expect(browser.fieldPage === guest, "the icon was the main window's tab's")
        #expect(browser.untouched == guestURL)
        browser.dismiss()
        #expect(browser.fieldPage === main)
    }
}
