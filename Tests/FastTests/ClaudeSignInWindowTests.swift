import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ClaudeSignInWindowTests {
    @Test func printedOAuthFallbackOpensWhenTheCLINeverInvokesBrowser() async throws {
        try #require(Store.testing)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-window-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("claude-fixture")
        let url = "https://127.0.0.1:9/oauth/authorize?state=synthetic-window"
        try "#!/bin/sh\nprintf '%s\\n' 'If the browser did not open, visit: \(url)'\n/bin/cat >/dev/null\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let domain = "claude-window-\(UUID())", settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        consent.beginConnection("claude")
        let permit = try #require(consent.connectionPermit("claude"))
        let browser = Browser(windowID: UUID()), agents = Agents()
        var pages: [Agents.SignInPage] = []
        let task = Task { @MainActor in
            await agents.connect("claude", binary: cli.path, env: ["PATH": "/usr/bin:/bin"], in: browser,
                                 limit: 12, permit: permit, page: { pages.append($0) })
        }
        defer {
            agents.cancelConnect("claude")
            consent.cancelConnections()
            browser.letGo()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id).json"))
                Store.settings.removeObject(forKey: "window.\(id).space")
            }
        }
        let deadline = Date().addingTimeInterval(6)
        while !pages.contains(.yab), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(pages.first == .opening)
        #expect(pages.contains(.yab), "A printed fallback must leave Opening and open the OAuth page")
        let tab = agents.signInTab("claude", privately: false)
        #expect((tab?.pending ?? tab?.address)?.absoluteString == url)
        agents.cancelConnect("claude")
        #expect(await task.value == .canceled)
        #expect(!pages.contains(.browser(nil)))
    }
}
