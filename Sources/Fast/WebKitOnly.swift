import AppKit
import WebKit

/// Explicit boundary for native WebKit features without a remote counterpart.
/// Ordinary navigation, scripts, geometry and pictures use PageHandle instead.
@MainActor
enum WebKitOnly {
    private static var reported = Set<String>()

    static func note(_ feature: String, engine: PageEngineKind) {
        let key = engine.rawValue + ":" + feature
        if reported.insert(key).inserted {
            print("YAB_PAGE_UNAVAILABLE \(engine.rawValue) \(feature): not available on this engine yet")
        }
    }

    static func page(_ page: (any PageHandle)?, for feature: String) -> PageView? {
        guard let page else { return nil }
        if let web = page.webKit { return web }
        note(feature, engine: page.engine)
        return nil
    }
}

extension Tab {
    /// Cookie-backed native reads must not borrow a WebKit configuration for
    /// a remote page. This does not build or wake either engine.
    func webKitStore(_ feature: String) -> WKWebsiteDataStore? {
        guard engineKind == .webKit else {
            WebKitOnly.note(feature, engine: engineKind)
            return nil
        }
        return store
    }

    func webKitOnly(_ feature: String, build: Bool = true) -> PageView? {
        let handle: (any PageHandle)? = build && !gone ? page : builtPage
        guard let handle else {
            if engineKind != .webKit { WebKitOnly.note(feature, engine: engineKind) }
            return nil
        }
        return WebKitOnly.page(handle, for: feature)
    }
}

extension PageEngineFactory {
    /// Native WebKit popup/auxiliary construction must retain its supplied
    /// related-view configuration even when ordinary tabs opt into Chromium.
    static var webKitOnly: PageEngineFactory {
        PageEngineFactory(kinds: [.webKit]) { tab, _ in tab.buildWebKitPage() }
    }
}
