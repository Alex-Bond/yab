import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// CEF can navigate its bootstrap blank document by fragment without a new
/// OnLoadStart. Only the requested URL may settle that initial navigation.
@MainActor @Suite(.serialized)
struct Seam2InitialNavigationTests {
    @Test(arguments: [false, true])
    func theRequestedBlankFragmentSettlesWithoutANewDocumentCommit(combined: Bool) {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        let remote = "initial-fragment-" + UUID().uuidString
        let target = "about:blank#requested"
        page.navigate(to: URLRequest(url: URL(string: target)!))
        page.adoptRemote(remote)
        defer {
            page.retire(call: false, pictureInPicture: false)
            ChromiumProcess.shared.detach(remote)
            tab.close()
        }
        page.receive(YabCoreEvent(name: "page.state", params: ["tab": .string(remote),
            "url": .string("about:blank"), "loading": .bool(false)]))
        #expect(page.isLoading, "the bootstrap is not the requested fragment")
        page.receive(YabCoreEvent(name: "page.state", params: ["tab": .string("stale"),
            "url": .string(target), "loading": .bool(false)]))
        #expect(page.isLoading, "a foreign tab cannot settle this navigation")
        var state: [String: JSONValue] = ["tab": .string(remote), "url": .string(target)]
        if combined { state["loading"] = .bool(false) }
        page.receive(YabCoreEvent(name: "page.state", params: state))
        #expect(page.url?.absoluteString == target)
        #expect(!page.isLoading, "the actual requested blank fragment has finished loading")
    }

    @Test func aBlankFragmentCannotSettleAnInitialHTTPSDocument() {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        let remote = "initial-document-" + UUID().uuidString
        page.navigate(to: URLRequest(url: URL(string: "https://initial.invalid/document")!))
        page.adoptRemote(remote)
        defer {
            page.retire(call: false, pictureInPicture: false)
            ChromiumProcess.shared.detach(remote)
            tab.close()
        }
        page.receive(YabCoreEvent(name: "page.state", params: ["tab": .string(remote),
            "url": .string("about:blank#incidental"), "loading": .bool(false)]))
        #expect(page.isLoading, "incidental blank content cannot accept the requested HTTPS document")
        page.receive(YabCoreEvent(name: "page.state", params: ["tab": .string(remote),
            "url": .string("about:blank#incidental"), "loading": .bool(false)]))
        #expect(page.isLoading, "a previous URL patch cannot rewrite the requested document")
    }
}
