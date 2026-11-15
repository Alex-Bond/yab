import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumScriptProfilesTests {
    @Test func theSyntheticCodeInboxDoesNotRequireAWebKitPage() {
        _ = NSApplication.shared
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in
            Issue.record("The fixture must not construct any page")
            return ChromiumPage(tab: tab)
        }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        let previous = MailCodes.fakeMail.withLock { value -> [Mailed]? in
            let old = value
            value = [Mailed(from: "Fixture", address: "codes@example.test", subject: "Your code",
                            text: "Verification code: 604418", at: Date())]
            return old
        }
        defer { MailCodes.fakeMail.withLock { $0 = previous }; tab.close() }
        var called = false
        MailCodes.unread(on: tab) { mail in
            called = true
            #expect(mail.count == 1)
            #expect(MailCodes.code(in: mail[0].text) == "604418")
        }
        #expect(called)
        #expect(tab.engineKind == .chromium)
        #expect(tab.builtPage == nil)
    }

    @Test func onlyAnEnabledJSONViewerInThisChromiumProfileTakesOver() throws {
        func item(_ id: String, enabled: Bool = true) throws -> ChromiumExtensions.Item {
            try ChromiumExtensions.Item(.object(["id": .string(id), "name": .string("Fixture"),
                "state": .string(enabled ? "ENABLED" : "DISABLED")]))
        }
        let viewer = try item("bcjindcccaagfpapjjmafapmmgkkhgoa")
        let disabled = try item(viewer.id, enabled: false)
        let unrelated = try item(String(repeating: "a", count: 32))
        #expect(JSONView.yieldsTo(chromium: [viewer], privateMode: false) == "JSON Formatter")
        #expect(JSONView.yieldsTo(chromium: [disabled, unrelated], privateMode: false) == nil)
        #expect(JSONView.yieldsTo(chromium: [], privateMode: false) == nil)
        #expect(JSONView.yieldsTo(chromium: [viewer], privateMode: true) == nil)
        // An extension listed in one profile never suppresses another profile.
        #expect(JSONView.yieldsTo(chromium: [unrelated], privateMode: false) == nil)
    }
}
