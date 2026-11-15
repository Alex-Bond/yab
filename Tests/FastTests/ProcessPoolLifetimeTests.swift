import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// Every WebKit process pool watches the Mac's sleep and wake
/// (WebCore::PowerObserver). One freed while a wake message is still on its
/// way leaves WebKit a block for a dead observer: crash in
/// PowerObserver::didReceiveSystemPowerNotification on 0.43.1 (register 1711).
/// Yab's web views keep to pools that live as long as the app.
@MainActor
@Suite(.serialized)
struct ProcessPoolLifetimeTests {
    private static func pools() -> [WKProcessPool] {
        let selector = NSSelectorFromString("_allProcessPoolsForTesting")
        guard WKProcessPool.responds(to: selector) else { return [] }
        return WKProcessPool.perform(selector)?.takeUnretainedValue() as? [WKProcessPool] ?? []
    }

    /// The way in: a web view made from a fresh configuration gets a pool of
    /// its own, and the pool is freed with the view.
    @Test func freshConfigurationMakesAPoolThatDiesWithItsView() async throws {
        try #require(WKProcessPool.responds(to: NSSelectorFromString("_allProcessPoolsForTesting")))
        _ = Web.pool
        weak var pool: WKProcessPool?
        autoreleasepool {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.loadHTMLString("<p>x</p>", baseURL: nil)
            pool = web.configuration.processPool
            #expect(pool !== Web.pool)
            #expect(pool !== WKWebViewConfiguration().processPool)
        }
        for _ in 0..<100 where pool != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(pool == nil, "the view's own pool outlived it")
    }

    /// An article printed to a PDF makes its view in the kept pool: no pool
    /// is made, so none is freed.
    @Test func offscreenPrintMakesNoPool() async throws {
        try #require(WKProcessPool.responds(to: NSSelectorFromString("_allProcessPoolsForTesting")))
        _ = Web.pool
        let before = Set(Self.pools().map(ObjectIdentifier.init))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let (printed, seen): (Bool, Set<ObjectIdentifier>) = await withCheckedContinuation { done in
            OffscreenPage.print("<h1>Title</h1><p>Words.</p>", base: nil, to: file) { result in
                done.resume(returning: ((try? result.get()) != nil, Set(Self.pools().map(ObjectIdentifier.init))))
            }
        }
        #expect(printed)
        #expect(seen.subtracting(before).isEmpty, "printing made a pool of its own")
    }

    /// The clipboard's HTML preview reads HTML in this process; it makes no pool.
    @Test func clipboardHTMLMakesNoPool() throws {
        try #require(WKProcessPool.responds(to: NSSelectorFromString("_allProcessPoolsForTesting")))
        _ = Web.pool
        let before = Set(Self.pools().map(ObjectIdentifier.init))
        _ = try NSAttributedString(data: Data("<b>bold</b> words".utf8), options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        #expect(Set(Self.pools().map(ObjectIdentifier.init)).subtracting(before).isEmpty)
    }

    /// Extensions' pages all run in one pool that lives as long as the app,
    /// not one tied to a controller.
    @Test func extensionPagesRunInTheKeptPool() async throws {
        try #require(Store.testing)
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Pool lifetime","version":"1.0","background":{"service_worker":"worker.js"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "self.ready = true;".write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)

        let owner = Extensions(signIn: UUID())
        #expect(owner.controller.configuration.webViewConfiguration?.processPool === Web.extensionPool)

        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.baseURL = try #require(URL(string: "\(Extensions.scheme)://pool\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))/"))
        try owner.controller.load(context)
        defer { try? owner.controller.unload(context) }

        let page = try #require(context.webViewConfiguration)
        #expect(page.processPool === Web.extensionPool)

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            context.loadBackgroundContent { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
        let key = "_backgroundWebView"
        try #require(context.responds(to: NSSelectorFromString(key)))
        let worker = try #require(context.value(forKey: key) as? WKWebView)
        #expect(worker.configuration.processPool === Web.extensionPool)
    }
}
