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

    @Test func embeddedExtensionOptionsStayInChromium() {
        let id = "nenlahapcbofgnanklpelkaejcehkggg"
        for text in ["chrome://extensions/?options=", "chrome://extensions?options="] {
            let url = URL(string: text + id)!
            #expect(ChromePages.place(of: url) == nil)
            #expect(ChromePages.typed(url.absoluteString) == nil)
            #expect(ChromePages.needsChromium(url))
        }
        // Only the actual options route bypasses Yab's settings, and a details
        // URL or invalid ID must not accidentally become privileged WebUI.
        #expect(place("chrome://extensions/?id=" + id) == .extensions(id))
        #expect(place("chrome://extension/?options=" + id) == .extensions(nil))
        #expect(place("chrome://extensions/?options=bad") == .extensions(nil))
        #expect(place("chrome://extensions/?options=") == .extensions(nil))
        #expect(place("chrome://extensions/shortcuts?options=" + id) == .shortcuts(nil))
    }

    @Test func singularExtensionAddress() {
        // The address actually typed by feedback #1632.
        #expect(place("chrome://extension") == .extensions(nil))
        #expect(ChromePages.typed("chrome://extension") == .extensions(nil))
        #expect(!ChromePages.needsChromium(URL(string: "chrome://extension")))
        #expect(place("https://extension") == nil)
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

    @Test func nativePagesAreAddresses() {
        for host in ["net-export", "version", "gpu", "net-internals", "inspect", "histograms", "chrome-urls", "flags"] {
            let url = URL(string: "chrome://\(host)/")!
            #expect(Address.url(from: "chrome://\(host)/") == url)
            #expect(ChromePages.needsChromium(url))
            #expect(ChromePages.typed(url.absoluteString) == nil)
        }
        #expect(ChromePages.needsChromium(URL(string: "CHROME://version/")))
        for text in ["chrome://extensions/", "chrome://settings/privacy", "chrome://newtab/", "https://version/", "chrome-extension://abc/options.html"] {
            #expect(!ChromePages.needsChromium(URL(string: text)))
        }
    }

    @MainActor @Test func nativePagesOverrideEnginePreferencesAndPressure() {
        let name = "ChromePagesTests." + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let sites = SiteEngineSettings(store: store)
        for base in [PageEngineKind.webKit, .chromium] {
            for held in [PageEngineKind?.none, .webKit, .chromium] {
                let decision = sites.decide(base, at: URL(string: "chrome://net-export/"), held: held, tight: true)
                #expect(decision.kind == .chromium)
            }
        }
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
