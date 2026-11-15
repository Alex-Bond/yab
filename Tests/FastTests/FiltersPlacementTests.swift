import AppKit
import Network
import Testing
import WebKit
@testable import Fast

/// Rule identity includes the list tail it must survive in. These tests
/// also run against the complete production converter in the golden path.
@Suite(.serialized)
struct FiltersPlacementTests {
    @Test func importantSurvivesPlainDuplicatesAcrossSources() throws {
        let plain = "||ads.example^"
        let important = plain + "$important"
        let exception = "@@" + plain
        let sources = [
            [plain, exception, important],
            [important, exception, plain],
            ["0.0.0.0 ads.example", exception, important],
            [plain + "\n" + important, exception, important + "\n" + plain],
        ]
        for texts in sources {
            let rules = Filters.convert(texts)
            #expect(rules.blocks.count == 2)
            #expect(rules.important.count == 2)
            #expect(rules.exceptions.count == 2)
            let split = try #require(Filters.lists(rules, perList: 100, cap: 300))
            let list = try #require(split.lists.first)
            let json = try #require(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
            let last = try #require(json.last?["action"] as? [String: String])
            #expect(last["type"] == "block")
        }
    }

    @Test func duplicatesAndBadfilterKeepTheirOriginalScope() {
        let plain = "/ad-banner.gif$image"
        let important = plain + ",important"
        let rules = Filters.convert([plain, plain, "@@" + plain, important, important])
        #expect(rules.blocks.count == 1)
        #expect(rules.important.count == 1)
        #expect(rules.exceptions.count == 1)
        let withdrawn = Filters.convert([plain, important, important + ",badfilter"])
        #expect(withdrawn.blocks.count == 1)
        #expect(withdrawn.important.isEmpty)
        let ordinary = Filters.convert([plain, "@@" + plain])
        #expect(ordinary.blocks.count == 1)
        #expect(ordinary.exceptions.count == 1)
        #expect(ordinary.important.isEmpty)
    }

    @Test func hidingExceptionsRetainTheirPlacementAndSideEffects() {
        let hide = "news.example##.promo"
        let ghide = "@@||news.example^$ghide"
        let ehide = "@@||news.example^$ehide"
        let document = "@@||news.example^$document"
        for texts in [[hide, ghide, ehide], [hide, ehide, ghide], [hide, document, ghide, ehide]] {
            let rules = Filters.convert(texts)
            #expect(rules.blocks.isEmpty)
            #expect(rules.unhide.count == 1)
            #expect(rules.exceptions.count == (texts.contains(document) ? 1 : 0))
        }
        let genericOnly = Filters.convert([hide, document, ghide, ghide])
        #expect(genericOnly.blocks.count == 1)
        #expect(genericOnly.unhide.count == 1)
        #expect(genericOnly.exceptions.count == 1)
    }

    @Test func sourcePartitioningPreservesDeterministicOutput() throws {
        let lines = ["||ads.example^", "@@||ads.example^", "||ads.example^$important", "##.ad", "news.example##.promo"]
        let joined = try #require(Filters.lists(Filters.convert([lines.joined(separator: "\n")])))
        let separate = try #require(Filters.lists(Filters.convert(lines + lines)))
        #expect(joined.lists == separate.lists)
        #expect(joined.left == separate.left)
        #expect(joined.hiding == separate.hiding)
    }

    @MainActor
    @Test func webKitBlocksImportantButKeepsOrdinaryExceptions() async throws {
        _ = NSApplication.shared
        let server = try PlacementServer()
        defer { server.stop() }
        let plain = "/ad-banner.gif$image"
        for (label, texts, blocked) in [
            ("important", [plain, "@@" + plain, plain + ",important"], true),
            ("ordinary-exception", [plain, "@@" + plain], false),
            ("no-rules", [], false),
        ] {
            let split = try #require(Filters.lists(Filters.convert(texts), perList: 100, cap: 300))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("filters-placement-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try #require(WKContentRuleListStore(url: directory))
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            for (index, json) in split.lists.enumerated() {
                let list = try await withCheckedThrowingContinuation { (done: CheckedContinuation<WKContentRuleList, Error>) in
                    store.compileContentRuleList(forIdentifier: "placement-\(index)", encodedContentRuleList: json) { list, error in
                        if let list { done.resume(returning: list) }
                        else { done.resume(throwing: error ?? PlacementFailure.compile) }
                    }
                }
                config.userContentController.add(list)
            }
            server.reset()
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
            web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/\(label)")!))
            let deadline = Date().addingTimeInterval(15)
            var settled = false
            while Date() < deadline {
                let value = try? await web.evaluateJavaScript("location.pathname === '/\(label)' && document.readyState === 'complete' && [...document.images].every(i => i.complete)")
                if value as? Bool == true { settled = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let paths = server.paths
            print("NETWORK_RECEIPT \(label) \(paths.sorted())")
            #expect(settled)
            #expect(paths.contains("/\(label)"))
            #expect(paths.contains("/normal.gif"))
            #expect(paths.contains("/ad-banner.gif") == !blocked)
            web.stopLoading()
        }
    }
}

private enum PlacementFailure: Error { case listener, compile }

/// Same localhost request receipt as FiltersTests, independent of page JS.
private final class PlacementServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var asked = Set<String>()
    private(set) var port: UInt16 = 0
    var paths: Set<String> { lock.lock(); defer { lock.unlock() }; return asked }
    func reset() { lock.lock(); asked = []; lock.unlock() }
    func stop() { listener.cancel() }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { throw PlacementFailure.listener }
        self.port = port
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.lock(); self.asked.insert(path); self.lock.unlock()
            let image = path.hasSuffix(".gif")
            let body = image ? Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
                : Data("<!doctype html><img src='/ad-banner.gif'><img src='/normal.gif'>".utf8)
            let type = image ? "image/gif" : "text/html"
            var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            reply.append(body)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
