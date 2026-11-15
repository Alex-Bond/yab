import Foundation
import Testing
@testable import Fast

struct ExtensionFragmentRoutingTests {
    @Test(arguments: ["chrome-extension", "webkit-extension"])
    func preferenceTabsBelongToTheCurrentDocument(scheme: String) throws {
        let page = try #require(URL(string: "\(scheme)://connector/preferences/preferences.html#general"))
        for fragment in ["general", "advanced", "", "export%20settings"] {
            let link = try #require(URL(string: "\(scheme)://connector/preferences/preferences.html#\(fragment)"))
            #expect(Browser.extensionFragment(link, on: page))
        }
    }

    @Test func anotherDocumentKeepsNormalRouting() throws {
        let page = try #require(URL(string: "chrome-extension://connector/preferences/preferences.html#general"))
        for address in [
            "chrome-extension://connector/preferences/preferences.html",
            "chrome-extension://connector/preferences/preferences.html?mode=2#advanced",
            "chrome-extension://connector/preferences/other.html#advanced",
            "chrome-extension://another/preferences/preferences.html#advanced",
            "webkit-extension://connector/preferences/preferences.html#advanced",
            "https://connector/preferences/preferences.html#advanced",
        ] {
            #expect(!Browser.extensionFragment(try #require(URL(string: address)), on: page))
        }
        #expect(!Browser.extensionFragment(page, on: nil))
        // Web anchors retain the web's existing modifier and Peek behavior.
        let web = try #require(URL(string: "https://example.com/page#first"))
        #expect(!Browser.extensionFragment(try #require(URL(string: "https://example.com/page#next")), on: web))
    }
}
