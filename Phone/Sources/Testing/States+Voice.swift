import Foundation

/// Voice search and the code scanner, from the right button's menu: the
/// held tab stack offering Voice Search and Scan QR Code after New Chat,
/// voice search listening with the words heard so far (and before any), and
/// the scanner's camera. The simulator can neither listen nor scan, so
/// these states put stand-ins in (Field/VoiceSearch, Field/CodeScanner).
extension StateCatalog {
    static let lumenCode = "https://lumen.events/e/design-systems-night"

    static let voice: [NamedState] = [
        NamedState("stack.menu.voice", "Stack menu: voice and QR", "New Tab, New Private Tab, New Chat, Voice Search, Scan QR Code · two recent · All Tabs.") { app in
            app.voice.useStandIn("lisbon weather october")
            app.scanner.useStandIn(lumenCode)
            await visitTabs(app, ["work-hn", "work-gh-pr"])
            try? await Task.sleep(for: .milliseconds(400))
            #if DEBUG
            TabStack.of(app).control?.presentMenuForTests()
            #endif
            try? await Task.sleep(for: .milliseconds(600))
        },
        NamedState("voice.1", "Listening", "From the Voice Search menu item: the mic lit, the heard “lisbon weather” already in the field, rows over it.") { app in
            app.voice.useStandIn("lisbon weather october", holdAfter: 2)
            app.openVoiceSearch()
            for _ in 0..<40 where app.field.text != "lisbon weather" { try? await Task.sleep(for: .milliseconds(100)) }
        },
        NamedState("voice.2", "Listening, quiet so far", "From the Voice Search menu item: the mic lit, “Listening…” in the field, no words yet.") { app in
            app.voice.useStandIn("lisbon weather october", holdAfter: 0)
            app.openVoiceSearch()
        },
        NamedState("scan.1", "Scanner", "From the Scan QR Code menu item: the camera full screen, “Point at a QR code” at the bottom, ✕ on top.") { app in
            app.scanner.useStandIn(lumenCode, waits: true)
            app.openScanner()
        },
    ]

    /// Each tab in front once, its page drawn, then the first again, so the
    /// stack has tabs used before this one.
    @MainActor
    private static func visitTabs(_ app: AppModel, _ ids: [Tab.ID]) async {
        _ = TabStack.of(app)
        let start = app.browser.tab?.id
        for id in ids + [start].compactMap({ $0 }) {
            app.browser.select(id)
            if let tab = app.browser.tab {
                app.pages.activate(tab)
                await app.pages.waitUntilPainted(tab.id, timeout: .seconds(8))
            }
        }
    }
}
