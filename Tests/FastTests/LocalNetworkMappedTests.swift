import Foundation
import Testing
import WebKit
@testable import Fast

struct LocalNetworkMappedTests {
    @Test func publicMappedAddressesNeverGetTheLocalPageExemption() throws {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(LocalNetwork.rules().utf8)) as? [[String: Any]])
        let home = try #require((rules.first?["trigger"] as? [String: Any])?["unless-frame-url"] as? [String])
        for address in ["[::ffff:808:808]", "[::ffff:8.8.8.8]", "[::ffff:ac20:1]", "[::ffff:6440:1].evil.example"] {
            let url = "http://\(address)/"
            #expect(!home.contains { url.range(of: $0, options: .regularExpression) != nil }, "Public page exempted: \(url)")
        }
        for address in ["[::ffff:7f00:1]", "[::ffff:127.0.0.1]", "[::ffff:c0a8:1]", "[::ffff:192.168.0.1]", "[::ffff:a00:1]", "[::ffff:ac10:1]", "[::ffff:6440:1]"] {
            let url = "http://\(address)/"
            #expect(home.contains { url.range(of: $0, options: .regularExpression) != nil }, "Local page not recognized: \(url)")
        }
    }

    @MainActor @Test func mappedPublicPageCannotSendALoopbackPixel() async throws {
        _ = await LocalNetwork.ready()
        let victim = try LocalNetworkFixture()
        defer { victim.stop() }
        for listed in [false, true] {
            let config = Web.configuration(shy: true, store: .nonPersistent())
            if !listed { config.userContentController.removeAllContentRuleLists() }
            let web = WKWebView(frame: .zero, configuration: config)
            let path = listed ? "/protected" : "/control"
            web.loadHTMLString("<img src='\(victim.root)\(path)'><script>window.started=true</script>", baseURL: URL(string: "http://[::ffff:808:808]/"))
            var started = false
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("window.started === true") as? Bool) == true { started = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(started)
            for _ in 0..<30 {
                if victim.requests.contains(where: { $0.path == path }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(victim.requests.contains(where: { $0.path == path }) == !listed)
            web.stopLoading()
        }
    }
}
