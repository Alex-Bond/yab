import Foundation
import Testing
@testable import Fast

/// Chrome's pages extensions send you to, and where Yab answers them
/// (ChromePages, feedback #163).
struct ChromePagesTests {
    private func place(_ text: String, opener: String? = nil) -> ChromePages.Place? {
        ChromePages.place(of: URL(string: text)!, opener: opener)
    }

    @Test func extensionsPages() {
        #expect(place("chrome://extensions/shortcuts", opener: "abc") == .shortcuts("abc"))
        #expect(place("chrome://extensions/shortcuts") == .shortcuts(nil))
        #expect(place("chrome://extensions/configureCommands", opener: "abc") == .shortcuts("abc"))
        #expect(place("chrome://extensions") == .extensions(nil))
        #expect(place("chrome://extensions/") == .extensions(nil))
        // The Great Suspender's two spellings of its own page.
        #expect(place("chrome://extensions?id=hlofigcdgjlnalbkeeinfcjceabpamci") == .extensions("hlofigcdgjlnalbkeeinfcjceabpamci"))
        #expect(place("chrome://extensions/?id=hlofigcdgjlnalbkeeinfcjceabpamci") == .extensions("hlofigcdgjlnalbkeeinfcjceabpamci"))
    }

    @Test func settingsAndNewTab() {
        #expect(place("chrome://settings") == .settings(.general))
        #expect(place("chrome://settings/passwords") == .settings(.passwords))
        #expect(place("chrome://password-manager/passwords") == .settings(.passwords))
        #expect(place("chrome://settings/content/notifications") == .settings(.privacy))
        #expect(place("chrome://settings/searchEngines") == .settings(.search))
        #expect(place("chrome://newtab") == .newTab)
        #expect(place("chrome://newtab/") == .newTab)
    }

    @Test func othersAreLeftAlone() {
        #expect(place("chrome://favicon/size/16@2x/https://example.com") == nil)
        #expect(place("chrome://history") == nil)
        #expect(place("https://extensions/shortcuts") == nil)
        #expect(place("chrome-extension://abc/options.html") == nil)
    }

    @Test func typed() {
        #expect(ChromePages.typed("  chrome://extensions/shortcuts ") == .shortcuts(nil))
        #expect(ChromePages.typed("CHROME://extensions") == .extensions(nil))
        // A fresh tab is what the field already is.
        #expect(ChromePages.typed("chrome://newtab") == nil)
        #expect(ChromePages.typed("chrome extensions") == nil)
        #expect(ChromePages.typed("extensions") == nil)
    }
}
