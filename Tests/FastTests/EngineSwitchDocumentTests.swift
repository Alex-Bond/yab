import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct EngineSwitchDocumentTests {
    private let url = URL(string: "https://switch.test/document")!
    private let html = """
    <style>body{height:3000px}</style><input id="draft"><input id="secret" type="password"><input type="file">
    <script>window.boot = [localStorage.getItem('account'),sessionStorage.getItem('draft')];</script>
    """

    private func loaded(_ view: PageView) async throws {
        for _ in 0..<250 where view.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!view.isLoading)
    }

    @Test func storagePrecedesPageScriptsAndOrdinaryFormsSurvive() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let source = PageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        source.navigate(html: html, base: url)
        try await loaded(source)
        _ = try await source.run("localStorage.setItem('account','synthetic'); sessionStorage.setItem('draft','session-draft'); document.querySelector('#draft').value='unfinished'; document.querySelector('#secret').value='do-not-transfer'; true")
        let transfer = try #require(try await EngineSwitchDocument.capture(from: source, at: url))
        #expect(!transfer.script.source.contains("do-not-transfer"))
        let destinationConfiguration = WKWebViewConfiguration()
        destinationConfiguration.websiteDataStore = .nonPersistent()
        destinationConfiguration.userContentController.addUserScript(transfer.script)
        let destination = PageView(frame: source.frame, configuration: destinationConfiguration)
        destination.navigate(html: html, base: url)
        try await loaded(destination)
        #expect(try await destination.run("JSON.stringify(boot)") as? String == "[\"synthetic\",\"session-draft\"]")
        #expect(try await destination.run("document.querySelector('#draft').value") as? String == "unfinished")
        #expect(try await destination.run("document.querySelector('#secret').value") as? String == "")
    }

    @Test func foreignURLsAndOversizeSnapshotsAreRefused() async throws {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigate(html: html, base: url)
        try await loaded(view)
        #expect(try await EngineSwitchDocument.capture(from: view, at: URL(string: "https://other.test/document")!) == nil)
        #expect(throws: EngineSwitchDocumentError.self) {
            try EngineSwitchDocument(url: url, json: "{\"url\":\"https://other.test/document\"}")
        }
        #expect(throws: EngineSwitchDocumentError.self) {
            try EngineSwitchDocument(url: url, json: String(repeating: "a", count: 513 * 1024))
        }
    }

    @Test func consumingTheHandoffPreservesScriptsInstalledByOtherOwners() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = PageView(frame: .zero, configuration: configuration)
        let transfer = try EngineSwitchDocument(url: url,
            json: "{\"url\":\"https://switch.test/document\",\"local\":[],\"session\":[],\"fields\":[],\"x\":0,\"y\":0}")
        let marker = WKUserScript(source: "globalThis.otherOwner = true", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        let controller = view.configuration.userContentController
        controller.addUserScript(marker)
        controller.addUserScript(transfer.script)
        transfer.removeScript(from: view)
        #expect(controller.userScripts.contains { $0 === marker })
        #expect(!controller.userScripts.contains { $0 === transfer.script })
    }
}
