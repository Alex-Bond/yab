import Foundation

/// Chrome's own pages an extension sends you to, or someone types: Yab has
/// a place for some of them, and that place opens instead. The Great
/// Suspender's "Configure shortcuts" sends its tab to
/// chrome://extensions/shortcuts with tabs.update; Yab routed that nowhere
/// and the button did nothing (feedback #163). Now:
///
/// - chrome://extensions/shortcuts: Settings › Shortcuts, at the commands of
///   the extension that asked, or the first extension's when nobody did;
/// - chrome://extensions, chrome://extensions/?id=X: Settings › Extensions,
///   or that extension's own page there;
/// - chrome://settings/…: the Settings page that holds the same things;
/// - chrome://newtab: a fresh tab's blank page, as tabs.create with no
///   address gives.
///
/// Other chrome:// pages belong to Chromium itself.
enum ChromePages {
    enum Place: Equatable {
        /// Settings › Shortcuts, at this extension's commands when known.
        case shortcuts(String?)
        /// Settings › Extensions, or this extension's page there.
        case extensions(String?)
        case settings(SettingsPage)
        case newTab
    }

    static let blank = URL(string: "about:blank")!

    /// Where Yab answers this address, nil for one that isn't chrome://
    /// or that Yab has no place for. `opener`: the extension whose page or
    /// worker asked, for the shortcuts' group to open at.
    static func place(of url: URL, opener: String? = nil) -> Place? {
        guard url.scheme?.lowercased() == "chrome" else { return nil }
        let host = url.host()?.lowercased() ?? ""
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "id" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        switch host {
        case "extensions", "extension":
            // Chrome embeds options_ui pages without open_in_tab inside this
            // WebUI. It must stay a Chromium document: Settings cannot host the
            // extension iframe. A details ?id= URL still belongs to Settings.
            if host == "extensions", path.isEmpty,
               URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "options" && $0.value.map(ChromiumExtensions.validID) == true }) == true {
                return nil
            }
            // configureCommands is the old name of the shortcuts page.
            if path == "shortcuts" || path == "configurecommands" { return .shortcuts(id ?? opener) }
            return .extensions(id)
        case "settings": return .settings(settingsPage(path))
        case "password-manager": return .settings(.passwords)
        case "newtab", "new-tab-page": return .newTab
        default: return nil
        }
    }

    /// WebUI pages cannot be hosted by WebKit or spared under memory pressure.
    static func needsChromium(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "chrome", let host = url.host(), !host.isEmpty else { return false }
        return place(of: url) == nil
    }

    /// chrome://settings/<path>, as Chromium names its sections.
    static func settingsPage(_ path: String) -> SettingsPage {
        let section = path.split(separator: "/").first.map(String.init) ?? ""
        switch section {
        case "passwords": return .passwords
        case "autofill", "addresses", "payments": return .autofill
        case "privacy", "clearbrowserdata", "content", "cookies", "security", "safetycheck", "sitedata": return .privacy
        case "search", "searchengines": return .search
        case "appearance": return .appearance
        case "fonts": return .websites
        case "syncsetup", "people", "manageprofile": return .sync
        default: return .general
        }
    }

    /// An address typed into the field that Yab answers itself.
    static func typed(_ text: String) -> Place? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("chrome://"), !text.contains(" "), let url = URL(string: text) else { return nil }
        guard let place = place(of: url), place != .newTab else { return nil }
        return place
    }

    /// The extension a page or worker belongs to, by its address's host.
    @MainActor
    static func opener(of url: URL?) -> String? {
        guard let url, let host = Browser.extensionHost(of: url) else { return nil }
        guard #available(macOS 15.4, *) else { return host }
        return Extensions.all.lazy.compactMap { $0.contexts.first { $0.value.baseURL.host == host }?.key }.first ?? host
    }

    /// What was opened last, and from where, for the bench.
    @MainActor static var last: [String: String] = [:]

    /// Opens the place in Settings. A new tab's blank page is the caller's
    /// to load, in the tab it has.
    @MainActor
    static func open(_ place: Place, in browser: Browser, from url: URL? = nil) {
        last = ["url": url?.absoluteString ?? "", "place": "\(place)"]
        switch place {
        case .shortcuts(let id):
            SettingsWindow.shared.showCommands(of: id, for: browser)
        case .extensions(let id):
            if let id, #available(macOS 15.4, *), Extensions.here.installed.contains(where: { $0.id == id }) {
                browser.openSettings(.extensions)
                SettingsWindow.shared.showExtension(id, for: browser)
            } else {
                browser.openSettings(.extensions)
            }
        case .settings(let page):
            browser.openSettings(page)
        case .newTab:
            break
        }
    }
}
