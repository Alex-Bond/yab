import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentSecretsTests {
    @Test nonisolated func extensionOriginsStayProtectedThroughWrappers() {
        for value in ["chrome-extension://vault/page.html", "webkit-extension://vault/page.html",
                      "moz-extension://vault/page.html", "safari-web-extension://vault/page.html",
                      "blob:chrome-extension://vault/id", "filesystem:chrome-extension://vault/temporary/a",
                      "blob:blob:blob:blob:blob:https://example.test/id"] {
            #expect(AgentSecrets.protected(URL(string: value)), "\(value) must be protected")
        }
        for value in ["https://example.test/chrome-extension://text", "http://127.0.0.1/page",
                      "about:blank", "blob:https://example.test/id"] {
            #expect(!AgentSecrets.protected(URL(string: value)), "\(value) is an ordinary origin")
        }
        #expect(!AgentSecrets.protected(nil))
    }

    @Test func secretProbeReturnsOnlyABoolean() async throws {
        let cases: [(String, Bool)] = [
            ("<title>Checkout</title><input type=password value=synthetic-password>", false),
            ("<h1>Recovery phrase</h1><p>SYNTHETIC_WORDS_ONLY</p>", true),
            ("<label>Seed phrase<input></label>", true),
            ("<input name=recovery_phrase value=SYNTHETIC_WORDS_ONLY>", true),
            ("<textarea>-----BEGIN PRIVATE KEY----- SYNTHETIC</textarea>", true),
            ("<input value='" + String(repeating: "a", count: 64) + "'>", true),
        ]
        for (html, expected) in cases {
            let page = await AgentKeysTests.page(html)
            let result = try await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false)
            #expect(result as? Bool == expected)
        }
    }

    @Test func openShadowRootsHaveTheSameSecretBoundary() async throws {
        let page = await AgentKeysTests.page("<title>Account</title><div id=host></div>")
        _ = try await page.call("""
        const root = document.getElementById('host').attachShadow({mode:'open'});
        root.innerHTML = '<div id=nested></div>';
        root.getElementById('nested').attachShadow({mode:'open'});
        return true;
        """, in: .agent)
        for (html, expected) in [
            ("<input aria-label='Full name' value=Ada>", false),
            ("<h1>Recovery phrase</h1><p>SYNTHETIC_WORDS_ONLY</p>", true),
            ("<input name=recovery_phrase value=SYNTHETIC_WORDS_ONLY>", true),
            ("<textarea>-----BEGIN PRIVATE KEY----- SYNTHETIC</textarea>", true),
            ("<input value='" + String(repeating: "a", count: 64) + "'>", true),
            ("<button>Save draft</button>", false),
        ] {
            _ = try await page.call("document.getElementById('host').shadowRoot.getElementById('nested').shadowRoot.innerHTML = html; return true;",
                                    arguments: ["html": html], in: .agent)
            let result = try await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false)
            #expect(result as? Bool == expected)
        }
    }

    @Test func unreadablyDeepShadowTreesFailClosed() async throws {
        let page = await AgentKeysTests.page("<title>Account</title><div id=host></div>")
        _ = try await page.call("""
        let host = document.getElementById('host');
        for (let n = 0; n < 33; n++) {
          const root = host.attachShadow({mode:'open'});
          host = document.createElement('div');
          root.appendChild(host);
        }
        return true;
        """, in: .agent)
        let result = try await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false)
        #expect(result as? Bool == true)
    }
}


@Suite(.serialized)
@MainActor
struct AgentSecretsTestsNativeModal {
    @Test func heldNativeQuestionReturnsOnlyStaticStatus() {
        _ = NSApplication.shared
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(bench: true, engine: .chromium, factory: factory)
        let other = Tab(bench: true, engine: .webKit)
        defer { tab.close(); other.close() }
        #expect(AgentSecrets.nativeQuestionReply([tab]) == nil)
        tab.asks = [PageAsk(kind: .confirm, host: "private.test", message: "PRIVATE_MODAL_CANARY")]
        let reply = AgentSecrets.nativeQuestionReply([tab])
        #expect(reply?["code"] as? String == "NATIVE_PAGE_QUESTION")
        #expect(reply?["needs_user"] as? Bool == true)
        #expect(reply?["asking"] == nil, "A native question must not replay the click through permit handoff-wait")
        #expect(!String(describing: reply).contains("PRIVATE_MODAL_CANARY"))
        #expect(!String(describing: reply).contains("private.test"))
        // The real reply wrapper must not append a queued page notice to
        // this deliberately data-free status.
        let browser = Browser(windowID: UUID())
        let bench = Bench()
        browser.lay([tab])
        defer { browser.lay([]); browser.letGo() }
        StuckWatch.notices[tab.id] = "PRIVATE_NOTICE_CANARY"
        defer { StuckWatch.notices[tab.id] = nil }
        var delivered: [String: Any] = [:]
        bench.agentCommand("snapshot", ["id": tab.id.uuidString], browser: browser) { delivered = $0 }
        #expect(delivered["code"] as? String == "NATIVE_PAGE_QUESTION")
        #expect(!String(describing: delivered).contains("PRIVATE_NOTICE_CANARY"))
        #expect(!String(describing: delivered).contains("PRIVATE_MODAL_CANARY"))
        other.asks = tab.asks
        #expect(AgentSecrets.nativeQuestionReply([other]) == nil)
        tab.asks = []
        #expect(AgentSecrets.nativeQuestionReply([tab]) == nil)
    }
}
