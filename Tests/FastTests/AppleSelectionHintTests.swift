import AppKit
import Testing
import WebKit
@testable import Fast

extension NativeAppleModelTests {
    /// Also runs unchanged on BASE. The ordinary selection path must respect
    /// an app opt-out, without depending on hardware/model availability.
    @Suite(.serialized)
    @MainActor
    struct AppleSelectionHintTests {
        @Test func disabledAppleModelDoesNotOfferAutomaticSelectionHint() async throws {
            _ = NSApplication.shared
            try #require(Store.testing && Store.world != nil)
            try #require(Store.settings !== UserDefaults.standard)
            let settings = Store.settings
            let keys = ["models.mac.disabled", "selection.hint.shown"]
            let old = keys.map { settings.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, old) {
                    if let value { settings.set(value, forKey: key) }
                    else { settings.removeObject(forKey: key) }
                }
                NotificationCenter.default.post(name: Notification.Name("YabAppleModelAccessChanged"), object: nil)
            }
            settings.set(true, forKey: "models.mac.disabled")
            settings.set(false, forKey: "selection.hint.shown")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Fast.Tab(bench: true, configuration: configuration)
            let web = tab.page
            web.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
            defer { web.stopLoading(); tab.close() }
            web.navigate(html: "<textarea id=t>These are seven words in an owned editable fixture.</textarea>",
                               base: URL(string: "https://apple-hint.invalid/"))
            var loaded = false
            for _ in 0..<200 {
                if (try? await web.fixtureExpression("document.getElementById('t') != null")) as? Bool == true { loaded = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(loaded, "The owned editable page must load before checking behavior")
            _ = try await web.fixtureExpression("const t=document.getElementById('t');t.focus();t.select();true")
            let commands = SelectionCommands()
            var snapshot: SelectionSnapshot?
            commands.peek(on: tab) { snapshot = $0 }
            for _ in 0..<200 where snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
            let selected = try #require(snapshot)
            try #require(selected.editable && selected.words > 5)
            commands.maybeHint(on: tab)
            for _ in 0..<50 where commands.hint == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(commands.hint == nil, "An app-disabled Apple model must not offer the automatic selection chip")
            #expect(!settings.bool(forKey: "selection.hint.shown"), "A suppressed hint must not consume the one-time education marker")
            #expect(commands.stage == .closed)
        }
    }
}
