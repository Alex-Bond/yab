import AppKit
import WebKit

/// Yab dressed from its own site: the dress-up block on a release's version
/// page (yetanotherbrowser.com/changelog) puts an app icon in the Dock or
/// drawings on the space with a click. Its buttons are yab-dress: links,
/// taken only from a click on yetanotherbrowser.com, so no other site can
/// change either; anywhere else they go nowhere. The page knows it is open
/// in Yab, and what Yab wears, from data-yab, data-yab-icon and
/// data-yab-drawings on its root, set here before its own scripts run.
@MainActor
enum Dress {
    static let scheme = "yab-dress"

    /// Our site, the one the updater reads (a test world's may be local).
    static func ours(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let site = Updater.site?.host()?.lowercased()
        return host == "yetanotherbrowser.com" || host == "www.yetanotherbrowser.com" || (site != nil && host == site)
    }

    /// The icons the site names, by its names for them.
    static let icons: [String: AppIconStyle] = [
        "default": .original,
        "halloween-pumpkin": .pumpkin,
        "halloween-ghost": .ghost,
        "halloween-mummy": .mummy,
        "halloween-witch": .witch,
        "first-edition": .firstEdition,
    ]

    static func name(_ style: AppIconStyle) -> String {
        icons.first { $0.value == style }?.key ?? style.rawValue
    }

    enum Ask: Equatable {
        case icon(AppIconStyle)
        case drawings(LookDrawings.Set?, strength: Double?)
        case gift(String)
    }

    /// What a yab-dress: link asks for: icon/NAME, or drawings/SET with
    /// ?strength= from 0 to 1, drawings/none for none.
    static func read(_ url: URL) -> Ask? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let rest = url.absoluteString.dropFirst(scheme.count + 1).drop { $0 == "/" }
        let parts = rest.split(separator: "?", maxSplits: 1)
        let path = parts.first.map { $0.split(separator: "/").map(String.init) } ?? []
        guard path.count == 2 else { return nil }
        switch path[0] {
        case "icon":
            return icons[path[1]].map { .icon($0) }
        case "gift":
            return FirstEdition.valid(path[1]) ? .gift(path[1]) : nil
        case "drawings":
            let set = LookDrawings.Set(rawValue: path[1])
            guard set != nil || path[1] == "none" else { return nil }
            let query = parts.count > 1 ? URLComponents(string: "?" + parts[1])?.queryItems : nil
            let strength = query?.first { $0.name == "strength" }?.value.flatMap(Double.init).map { min(1, max(0, $0)) }
            return .drawings(set, strength: strength)
        default:
            return nil
        }
    }

    /// A yab-dress: link clicked on a page: worn, when the page is ours and
    /// it was a click. True when it was one of ours, done or not, so it is
    /// never handed to another app.
    static func take(_ url: URL, from webView: any PageHandle, page: URL?, clicked: Bool, in browser: Browser) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }
        let testSite = Store.testing && page?.scheme == "http" && page?.host() == Updater.site?.host()
        guard clicked, page?.scheme == "https" || page?.host() == "localhost" || testSite,
              ours(page?.host()), let ask = read(url) else { return true }
        switch ask {
        case .gift(let token):
            guard FirstEdition.allows(token: token, page: page, clicked: clicked) else { return true }
            Task { @MainActor [weak webView, weak browser] in
                var detail: [String: String] = [:]
                do {
                    try await FirstEdition.claim(token)
                    AppIconStyle.firstEdition.choose()
                    // One line in the corner, under Notice.longest: the longer
                    // thank-you was cut in its middle.
                    browser?.announce("First Edition is yours, thanks", mark: "brand.blobplus")
                } catch {
                    detail["error"] = error.localizedDescription
                }
                // A navigation during the request must not deliver a result
                // (or dataset) into an unrelated page.
                guard let webView, webView.url == page else { return }
                let data = (try? JSONSerialization.data(withJSONObject: detail)) ?? Data("{}".utf8)
                let json = String(decoding: data, as: UTF8.self)
                webView.runInYab(mark(browser) + "document.dispatchEvent(new CustomEvent('yab:gift', {detail: \(json)}));")
            }
            return true
        case .icon(let style):
            guard style.unlocked, AppIconStyle.choices.contains(style) else { break }
            style.choose()
        case .drawings(let set, let strength):
            let prefs = browser.prefs
            prefs.lookDrawings = set?.rawValue ?? ""
            if let strength { prefs.lookDrawingsStrength = strength }
            if set != nil, prefs.backdrop != .color { prefs.backdrop = .color }
            browser.setSpacePaint(browser.spaceID, to: SpacePaint(prefs))
        }
        Halloween.dressedUp()
        webView.runInYab(mark(browser) + "document.dispatchEvent(new CustomEvent('yab:dress'));")
        return true
    }

    /// The page's root told what Yab is and wears.
    static func mark(_ browser: Browser?) -> String {
        let values = [
            "yab": Updater.version,
            "yabIcon": name(AppIconStyle.saved),
            "yabGifts": "1",
            "yabDrawings": LookDrawings.Set(rawValue: browser?.prefs.lookDrawings ?? "")?.rawValue ?? "none",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return "Object.assign(document.documentElement.dataset, \(json));"
    }

    /// Before the page's scripts, on our site only.
    static func script(_ browser: Browser?) -> WKUserScript {
        WKUserScript(source: "(() => { if (document.documentElement) { \(mark(browser)) } })();",
                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
    }
}
