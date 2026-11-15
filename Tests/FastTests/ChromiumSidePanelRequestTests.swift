import Foundation
import Testing
import YabCoreClient
@testable import Fast

/// #1917: chrome.sidePanel.open() reaches Yab as `extension.sidePanelOpen`
/// (CEF patch 0095). Only an extension's own panel page is shown.
struct ChromiumSidePanelRequestTests {
    private let imageye = "agionbommeaifngbhincahgmoflcikhm"

    private func event(_ id: String, _ url: String) -> [String: JSONValue] {
        ["extensionId": .string(id), "url": .string(url), "tab": .string("t1")]
    }

    @Test func acceptsTheExtensionsOwnPanelPageWithItsQuery() throws {
        let request = try #require(ChromiumSidePanel.requested(
            event(imageye, "chrome-extension://\(imageye)/popup.html?tabId=1234")))
        #expect(request.extensionID == imageye)
        #expect(request.url.absoluteString == "chrome-extension://\(imageye)/popup.html?tabId=1234")
    }

    @Test func refusesAnotherExtensionsOrigin() {
        let other = "abcdefghijklmnopabcdefghijklmnop"
        #expect(ChromiumSidePanel.requested(event(imageye, "chrome-extension://\(other)/panel.html")) == nil)
    }

    @Test func refusesWebAndOtherSchemes() {
        #expect(ChromiumSidePanel.requested(event(imageye, "https://\(imageye)/popup.html")) == nil)
        #expect(ChromiumSidePanel.requested(event(imageye, "javascript:alert(1)")) == nil)
        #expect(ChromiumSidePanel.requested(event(imageye, "file:///etc/hosts")) == nil)
    }

    @Test func refusesCredentialsAndPorts() {
        #expect(ChromiumSidePanel.requested(event(imageye, "chrome-extension://u:p@\(imageye)/popup.html")) == nil)
        #expect(ChromiumSidePanel.requested(event(imageye, "chrome-extension://\(imageye):80/popup.html")) == nil)
    }

    @Test func refusesInvalidExtensionIDs() {
        for id in ["", "agionbommeaifngbhincahgmoflcikh", "agionbommeaifngbhincahgmoflcikhmm",
                   "AGIONBOMMEAIFNGBHINCAHGMOFLCIKHM", "zgionbommeaifngbhincahgmoflcikhm", "../ionbommeaifngbhincahgmoflcikhm"] {
            #expect(!ChromiumSidePanel.validExtensionID(id))
            #expect(ChromiumSidePanel.requested(event(id, "chrome-extension://\(id)/popup.html")) == nil)
        }
        #expect(ChromiumSidePanel.validExtensionID(imageye))
    }

    @Test func refusesMissingOrMistypedFields() {
        #expect(ChromiumSidePanel.requested([:]) == nil)
        #expect(ChromiumSidePanel.requested(["extensionId": .string(imageye)]) == nil)
        #expect(ChromiumSidePanel.requested(["extensionId": .string(imageye), "url": .number(1)]) == nil)
        #expect(ChromiumSidePanel.requested(event(imageye, "")) == nil)
        let long = "chrome-extension://\(imageye)/" + String(repeating: "a", count: 9000)
        #expect(ChromiumSidePanel.requested(event(imageye, long)) == nil)
    }
}
