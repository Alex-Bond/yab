import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// What the local network list costs a page: the same pages with it and
/// without it, in turns, in one process. Run on its own:
/// YAB_TEST_FILTER=Cost ./farm test -- --no-parallel --filter LocalNetworkCost
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAB_TEST_FILTER"]?.contains("Cost") == true))
struct LocalNetworkCostTests {
    static let pictures = 40
    static let rounds = 15

    @MainActor private static func view(listed: Bool) async -> PageView {
        _ = await LocalNetwork.ready()
        let config = Web.configuration(shy: true, store: .nonPersistent())
        if !listed { config.userContentController.removeAllContentRuleLists() }
        return PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    }

    /// From asking for the page to its last picture, in ms: the wall time
    /// from here, and the page's own count from its navigation's start.
    @MainActor private static func sample(_ url: URL, listed: Bool) async throws -> (wall: Double, page: Double) {
        let web = await view(listed: listed)
        defer { web.stopLoading() }
        let asked = Date().timeIntervalSince1970 * 1000
        _ = web.load(URLRequest(url: url))
        for _ in 0..<300 {
            if let done = try? await web.evaluateJavaScript("window.doneAt ? [window.doneAt, window.pageMs] : null") as? [Double] {
                return (done[0] - asked, done[1])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw URLError(.timedOut)
    }

    private static func page(_ origin: String) -> String {
        let images = (0..<pictures).map { "<img src='\(origin)/p\($0).svg?\(UUID().uuidString)' onload='loaded()' onerror='loaded()'>" }.joined()
        return """
        <script>let n=0;function loaded(){if(++n===\(pictures)){window.pageMs=performance.now();window.doneAt=Date.now()}}</script>\(images)
        """
    }

    private static func stats(_ xs: [Double]) -> (p50: Double, p90: Double) {
        let s = xs.sorted()
        return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))])
    }

    @MainActor @Test func pagesLoadAsFastWithTheList() async throws {
        let server = try LocalNetworkFixture(); defer { server.stop() }
        for i in 0..<Self.pictures {
            var reply = LocalNetworkFixture.Reply("<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><rect width='8' height='8' fill='#\(String(format: "%06x", i * 4000))'/></svg>")
            reply.type = "image/svg+xml"
            server.route("/p\(i).svg", reply)
        }
        let named = "http://127.0.0.1.sslip.io:\(server.port)"
        _ = try await URLSession.shared.data(from: URL(string: named + "/warm")!)
        server.route("/public", .init(Self.page(named)))
        server.route("/local", .init(Self.page(server.root)))
        // Fixture paths ignore the query, so every round's pictures are new.
        let pages = [("website", URL(string: named + "/public")!), ("local page", URL(string: server.root + "/local")!)]
        // Warm the process pool and the caches both ways first.
        for (_, url) in pages { for listed in [false, true] { _ = try await Self.sample(url, listed: listed) } }
        var report: [String] = []
        for (name, url) in pages {
            var times: [Bool: [(Double, Double)]] = [false: [], true: []]
            for round in 0..<Self.rounds {
                // ABBA, then BAAB: neither goes first more often.
                let order = round % 2 == 0 ? [false, true, true, false] : [true, false, false, true]
                for listed in order { times[listed]!.append(try await Self.sample(url, listed: listed)) }
            }
            let a = (wall: Self.stats(times[false]!.map(\.0)), page: Self.stats(times[false]!.map(\.1)))
            let b = (wall: Self.stats(times[true]!.map(\.0)), page: Self.stats(times[true]!.map(\.1)))
            let line = String(format: "LOCAL_NETWORK_COST %@ n=%d wall p50 %.1f→%.1f p90 %.1f→%.1f | page p50 %.1f→%.1f p90 %.1f→%.1f ms",
                              name, times[true]!.count, a.wall.p50, b.wall.p50, a.wall.p90, b.wall.p90, a.page.p50, b.page.p50, a.page.p90, b.page.p90)
            print(line)
            report.append(line)
            // Chrome-parity is the point, but never at a cost a person feels.
            #expect(b.page.p50 <= a.page.p50 * 1.05 + 5, "\(line)")
        }
        // Compiling, the first launch only, and looking up, every launch after.
        let store = try #require(WKContentRuleListStore.default())
        let text = LocalNetwork.rules()
        let name = "local-network-cost-\(UUID().uuidString)"
        var t = CACurrentMediaTime()
        _ = try await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: text)
        let compile = (CACurrentMediaTime() - t) * 1000
        t = CACurrentMediaTime()
        _ = try await store.contentRuleList(forIdentifier: name)
        let lookup = (CACurrentMediaTime() - t) * 1000
        try? await store.removeContentRuleList(forIdentifier: name)
        print(String(format: "LOCAL_NETWORK_COST list rules=%d compile %.1f ms lookup %.2f ms", (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])?.count ?? 0, compile, lookup))
    }
}
