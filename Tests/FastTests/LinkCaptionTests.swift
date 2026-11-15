import Foundation
import Testing
@testable import Fast

/// Synthetic URL values only; no file is opened and no browser is created.
struct LinkCaptionTests {
    @Test func completedUntitledFilesUseTheExistingAddressDisplay() throws {
        for text in ["file:///fixture/index.html", "file:///fixture/My%20Site/a%20b.html", "file:///fixture/%E9%A1%B5%E9%9D%A2.html"] {
            let url = try #require(URL(string: text))
            #expect(url.isFileURL && (url.host()?.isEmpty ?? true))
            let caption = LinkCaption.hostless(url, title: "", loading: false)
            #expect(caption == Address.shown(url))
            #expect(!caption.isEmpty && caption != "Loading")
        }
    }

    @Test func pendingFilesAndEveryNonemptyTitleKeepTheirPriorWords() throws {
        let url = try #require(URL(string: "file:///fixture/index.html"))
        #expect(LinkCaption.hostless(url, title: "", loading: true) == "Loading")
        for title in ["Local document", "Loading", " "] {
            for loading in [false, true] {
                #expect(LinkCaption.hostless(url, title: title, loading: loading) == title)
            }
        }
    }

    @Test func hostlessNonFilesKeepLoadingAndTheirDocumentTitles() throws {
        for text in ["about:blank", "data:text/html,%3Cp%3Efixture%3C/p%3E"] {
            let url = try #require(URL(string: text))
            #expect(!url.isFileURL && (url.host()?.isEmpty ?? true))
            for loading in [false, true] {
                #expect(LinkCaption.hostless(url, title: "", loading: loading) == "Loading")
                #expect(LinkCaption.hostless(url, title: "Document", loading: loading) == "Document")
            }
        }
    }

    @Test func completionAndLaterTitlesUseOnlyTheSuppliedPageValues() throws {
        let own = try #require(URL(string: "file:///fixture/own.html"))
        let other = try #require(URL(string: "file:///fixture/other.html"))
        #expect(LinkCaption.hostless(own, title: "", loading: true) == "Loading")
        #expect(LinkCaption.hostless(own, title: "", loading: false) == Address.shown(own))
        #expect(LinkCaption.hostless(other, title: "Other page", loading: false) == "Other page")
        #expect(LinkCaption.hostless(own, title: "Own title arrived", loading: false) == "Own title arrived")
        #expect(LinkCaption.hostless(own, title: "", loading: false) == Address.shown(own))
    }
}
