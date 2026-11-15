import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumDocumentTitleTests {
    @Test func onlyADocumentCommitResetsTheTitle() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let remote = "document-title-" + UUID().uuidString
        page.adoptRemote(remote)
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        func receive(_ name: String, _ fields: [String: JSONValue]) {
            var fields = fields
            fields["tab"] = .string(remote)
            page.receive(YabCoreEvent(name: name, params: fields))
        }
        receive("page.state", ["url": .string("https://example.test/old"), "title": .string("Old title")])
        receive("page.started", [:])
        #expect(page.title == "Old title", "A pending navigation still shows the old document")
        receive("page.state", ["url": .string("https://example.test/old#fragment")])
        #expect(page.title == "Old title", "Same-document navigation retains its title")
        receive("page.committed", ["url": .string("https://example.test/new")])
        #expect(page.title == "")
        receive("page.state", ["title": .string("Destination title")])
        #expect(page.title == "Destination title")
    }
}
