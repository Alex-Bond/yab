import AppKit
import SwiftUI
import Testing
@testable import Fast
@testable import MailCore

/// Opt-in captures of the actual native views, without opening the ordinary app.
@MainActor
struct FeedbackVisualTests {
    @Test func captureFeedbackChanges() async throws {
        guard let folder = ProcessInfo.processInfo.environment["YAB_FEEDBACK_SHOTS"] else { return }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let previous = (prefs.sidebar, prefs.addressBar, prefs.usesSpaces, prefs.sideWidth)
        defer {
            prefs.sidebar = previous.0; prefs.addressBar = previous.1
            prefs.usesSpaces = previous.2; prefs.sideWidth = previous.3
            browser.tabs.forEach { $0.close() }
        }
        prefs.usesSpaces = true; prefs.addressBar = false; prefs.sideWidth = 260
        browser.spaces = (1...8).map { Space(id: UUID(), name: "Space \($0)", icon: "●", ownSignIns: false) }
        browser.spaceID = browser.spaces[5].id
        let tab = browser.open(URL(string: "about:blank#feedback")!, foreground: true)
        tab.restore(url: URL(string: "about:blank#feedback")!, title: "Example page")
        browser.dismiss()
        prefs.sidebar = false
        try await save(TabBar(browser: browser).frame(width: 900, height: Metrics.strip), to: output.appendingPathComponent("navigation-left.png"))
        prefs.sidebar = true
        try await save(SideBar(browser: browser, prefs: prefs).frame(width: 260, height: 540), to: output.appendingPathComponent("sidebar-spaces.png"))
        let meeting = Meeting(id: "visual", title: "Product review", start: Date().addingTimeInterval(45), end: Date().addingTimeInterval(1800), link: URL(string: "https://meet.google.com/abc-defg-hij"))
        let wanted = Meetings.shared.wanted
        Meetings.shared.wanted = true
        Meetings.shared.pretend([meeting])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BrowserWindows.shared.register(window, for: browser)
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); Meetings.shared.pretend(nil); Meetings.shared.wanted = wanted }
        try await save(Notice(browser: browser, toaster: browser.toaster, tidier: browser.tidier, agents: Agents.shared, top: 8).frame(width: 640, height: 60, alignment: .topTrailing), to: output.appendingPathComponent("meeting-reminder.png"))
        print("Feedback screenshots: \(output.path)")
    }

    private func save<V: View>(_ view: V, to file: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
}
