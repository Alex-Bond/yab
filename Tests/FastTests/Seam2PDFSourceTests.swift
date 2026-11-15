import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct Seam2PDFSourceTests {
    @Test(arguments: [PageEngineKind.webKit, .chromium])
    func nativePDFSourceNeverSubstitutesForARemotePage(engine: PageEngineKind) async throws {
        let bytes = Data("Disposable native source fixture".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("seam2-source-\(UUID().uuidString).pdf")
        try bytes.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        var builds = 0
        let factory = PageEngineFactory(kinds: [engine]) { tab, kind in
            builds += 1
            if kind == .webKit { return tab.buildWebKitPage() }
            return ChromiumPage(tab: tab)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration, engine: engine, factory: factory)
        defer { tab.close() }
        tab.restore(url: file, title: "PDF source fixture")
        #expect(tab.engineKind == engine)
        let received: Data? = await withCheckedContinuation { continuation in
            PDFPaper.bytes(of: tab) { continuation.resume(returning: $0) }
        }
        #expect(received == (engine == .webKit ? bytes : nil))
        #expect(builds == 0 && tab.builtPage == nil)
    }
}
