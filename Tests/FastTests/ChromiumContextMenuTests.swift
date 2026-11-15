import Foundation
import Testing
import YabCoreClient
@testable import Fast

@MainActor
struct ChromiumContextMenuTests {
    private func context(_ fields: [String: JSONValue]) throws -> ChromiumMenuContext {
        var p: [String: JSONValue] = ["request": .string("r1"), "x": .number(40), "y": .number(60),
                                      "devToolsFrontend": .bool(true)] // The rows these tests name; Inspect has its own.
        p.merge(fields) { $1 }
        return try #require(ChromiumMenuContext(p))
    }
    private func ids(_ rows: [ChromiumMenuRow?]) -> [String] { rows.map { $0?.id ?? ($0 == nil ? "-" : $0!.title) } }
    private func rows(_ c: ChromiumMenuContext, back: Bool = false, askable: Bool = true) -> [ChromiumMenuRow?] {
        ChromiumMenuRow.rows(for: c, searchName: "Kagi", canGoBack: back, canGoForward: false, askable: askable)
    }

    @Test func pagesOfferInspectAndDevToolsItselfDoesNot() throws {
        let page = rows(try context(["devToolsFrontend": .bool(false)]))
        #expect(page.last??.id == "WKMenuItemIdentifierInspectElement")
        #expect(!ids(rows(try context([:]))).contains("WKMenuItemIdentifierInspectElement"))
    }

    @Test func linkRowsMatchWebKitIdentifiersAndCopyTheUnfilteredAddress() throws {
        let c = try context(["link": .string("https://example.org/a"), "unfilteredLink": .string("https://example.org/a#raw")])
        let menu = rows(c)
        #expect(ids(menu) == ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierOpenLink",
                              "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink"])
        #expect(menu[3]?.action == .copy("https://example.org/a#raw"))
        #expect(menu[0]?.action == .openTab(URL(string: "https://example.org/a")!))
    }

    @Test func mailtoLinkCopiesTheAddressAndOpensNoTab() throws {
        let menu = rows(try context(["link": .string("mailto:ada%40example.org?subject=hi")]))
        #expect(ids(menu) == ["WKMenuItemIdentifierCopyLink", "YabCopyEmailAddress"])
        #expect(menu[1]?.action == .copy("ada@example.org"))
    }

    @Test func scriptLinksAreNotOffered() throws {
        let menu = rows(try context(["link": .string("javascript:alert(1)")]))
        #expect(ids(menu) == ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload"])
    }

    @Test func imageRowsGoThroughYabsImageActions() throws {
        let image = URL(string: "https://cdn.example/p.png")!
        let c = try context(["source": .string(image.absoluteString), "media": .number(1), "hasImage": .bool(true)])
        let menu = rows(c)
        #expect(ids(menu) == ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
                              "WKMenuItemIdentifierCopyImage", "YabCopyImageAddress", "YabAskAboutImage"])
        #expect(menu.compactMap { $0?.action } == [.image(.open, image), .image(.download, image), .image(.copy, image),
                                                   .image(.address, image), .image(.ask, image)])
        #expect(!ids(rows(c, askable: false)).contains("YabAskAboutImage"))
    }

    @Test func linkedImageHasBothSections() throws {
        let c = try context(["link": .string("https://example.org/"), "source": .string("https://cdn.example/p.png"),
                             "media": .number(1), "hasImage": .bool(true)])
        let menu = ids(rows(c))
        #expect(menu.firstIndex(of: "-") == 4)
        #expect(menu.contains("WKMenuItemIdentifierCopyLink") && menu.contains("WKMenuItemIdentifierCopyImage"))
    }

    @Test func selectionLooksUpSearchesAndCopiesThroughChrome() throws {
        let c = try context(["selection": .string("  example.com  "), "chrome": .array([.number(50150)])])
        let menu = rows(c)
        #expect(ids(menu) == ["WKMenuItemIdentifierLookUp", "YabGoToSelectedURL", "WKMenuItemIdentifierSearchWeb", "-",
                              "WKMenuItemIdentifierCopy"])
        #expect(menu[2]?.title == "Search with Kagi")
        #expect(menu[2]?.action == .search("example.com"))
        #expect(menu[4]?.action == .chrome(50150))
        let long = rows(try context(["selection": .string(String(repeating: "word ", count: 20))]))
        #expect(long[0]?.title.count ?? 0 < 45)
    }

    @Test func editableFieldOffersSuggestionsAndOnlyOfferedEditCommands() throws {
        let c = try context(["editable": .bool(true), "misspelled": .string("teh"),
                             "suggestions": .array([.string("the"), .string("tech")]),
                             "chrome": .array([.number(50152)])])
        let menu = rows(c)
        #expect(menu.prefix(2).map { $0?.action } == [.replace("the"), .replace("tech")])
        #expect(menu[2] == nil)
        #expect(menu.suffix(3).map { $0?.enabled } == [false, false, true])
        #expect(menu.last??.action == .chrome(50152))
    }

    @Test func blankPageHasHistoryRowsAndExtensionRowsLast() throws {
        let c = try context(["extensions": .array([
            .object(["command": .number(49001), "label": .string("Translate with Ext"), "enabled": .bool(true), "rows": .array([])]),
            .object(["command": .number(49002), "label": .string("Ext"), "enabled": .bool(true), "rows": .array([
                .object(["command": .number(49003), "label": .string("Inner"), "enabled": .bool(true), "checked": .bool(true), "rows": .array([])])])])])])
        let menu = rows(c, back: true)
        #expect(ids(menu).prefix(4) == ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload", "-"])
        #expect(menu[0]?.enabled == true && menu[1]?.enabled == false)
        #expect(menu[4]?.action == .chrome(49001))
        #expect(menu[5]?.action == nil && menu[5]?.rows.first??.action == .chrome(49003))
        #expect(menu[5]?.rows.first??.checked == true)
    }

    @Test func malformedEventIsRefused() {
        #expect(ChromiumMenuContext(["x": .number(1)]) == nil)
        #expect(ChromiumMenuContext(["request": .string("")]) == nil)
    }
}
