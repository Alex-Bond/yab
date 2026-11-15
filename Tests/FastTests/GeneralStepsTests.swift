import AppKit
import SwiftUI
import Testing
@testable import Fast

/// One at a time: both read the one count of lookups.
@MainActor @Suite(.serialized)
struct GeneralStepsTests {
    /// Settings › General's Open links in Yab step names the app links go
    /// to now, from what DefaultBrowser found off the main thread. Drawing
    /// it asks macOS nothing: on macOS 27's beta each name or icon lookup
    /// held the main thread about 5 s, and General drew it at every redraw.
    @Test func drawingTheDefaultStepLooksNothingUp() async throws {
        let browser = Browser(windowID: UUID())
        let lookups = FinderLooks.lookups, drawn = GeneralSteps.drawnDefaultStep
        let steps = GeneralSteps(browser: browser, bringing: Bringing(), model: SettingsModel(), isDefault: false, makeDefault: {})
        let host = NSHostingView(rootView: Form { steps }.formStyle(.grouped).frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where GeneralSteps.drawnDefaultStep == drawn {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(GeneralSteps.drawnDefaultStep > drawn)
        // Drawn again, as a page switch or a Browser change would.
        host.rootView = Form { steps }.formStyle(.grouped).frame(width: 600, height: 401)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(FinderLooks.lookups == lookups)
    }

    /// Two asking for one app's look at once share one lookup, off the main
    /// thread, and asking later is answered from what is kept.
    @Test func oneLookupPerPath() async {
        let path = "/System/Library/CoreServices/Finder.app"
        let before = FinderLooks.lookups
        async let first = FinderLooks.look(path)
        async let second = FinderLooks.look(path)
        let (a, b) = await (first, second)
        #expect(a.icon === b.icon)
        #expect(!a.name.isEmpty && !a.name.hasSuffix(".app"))
        let after = FinderLooks.lookups
        #expect(after - before <= 1)
        #expect(FinderLooks.kept(path)?.icon === a.icon)
        _ = await FinderLooks.look(path)
        #expect(FinderLooks.lookups == after)
    }
}
