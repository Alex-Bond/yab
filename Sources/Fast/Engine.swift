import Foundation

// What to do with words that aren't a place: ask the engine picked in
// Settings › General, Google unless another is.
//
// The field still tells an address from a phrase, typing a domain goes
// straight there, without a round trip through anyone's results page. Only
// what can't be a place gets searched.
//
// The choice is read from the settings file each time, not from
// `Preferences`: the history page and extensions ask from off the main
// thread, and a search is rare enough that one read costs nothing.

enum Engine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, ecosia, startpage, kagi, brave, qwant, custom

    static let standard = Engine.google
    static let key = "search.engine"
    static let customKey = "search.custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        case .kagi: return "Kagi"
        case .brave: return "Brave Search"
        case .qwant: return "Qwant"
        case .custom: return "Other…"
        }
    }

    /// The results page, with `%s` where the words go.
    func template(custom: String) -> String {
        switch self {
        case .google: return "https://www.google.com/search?q=%s"
        case .duckduckgo: return "https://duckduckgo.com/?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        case .startpage: return "https://www.startpage.com/sp/search?query=%s"
        case .kagi: return "https://kagi.com/search?q=%s"
        case .brave: return "https://search.brave.com/search?q=%s"
        case .qwant: return "https://www.qwant.com/?q=%s"
        case .custom:
            // One that doesn't hold up searches Google rather than nowhere.
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return Engine.accepts(trimmed) ? trimmed : Engine.standard.template(custom: "")
        }
    }

    /// What the row under the field says the words go to: the engine's
    /// name, or for one of your own, its site.
    func name(custom: String) -> String {
        guard self == .custom else { return title }
        // An extension's engine, picked in Search with: its own name.
        if Store.settings.string(forKey: "search.customExtension") != nil,
           let name = Store.settings.string(forKey: "search.customName") { return name }
        guard let host = Engine.host(of: custom) else { return Engine.standard.title }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - the one in use

    static var current: Engine {
        Store.settings.string(forKey: key).flatMap(Engine.init) ?? standard
    }

    static var customTemplate: String {
        Store.settings.string(forKey: customKey) ?? ""
    }

    static var name: String { current.name(custom: customTemplate) }

    /// A place if it can be one, a search if it can't.
    static func destination(for typed: String) -> URL? {
        Address.url(from: typed) ?? url(for: typed)
    }

    static func url(for text: String) -> URL? {
        url(for: text, template: current.template(custom: customTemplate))
    }

    // MARK: - templates

    /// An address of your own is taken only if it is a web address with
    /// `%s` in it, and the words can't move it to another site: `%s` in the
    /// host would let what you type choose where it goes.
    static func accepts(_ template: String) -> Bool {
        host(of: template) != nil
    }

    static func url(for text: String, template: String) -> URL? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Everything a query string can't carry raw, including the plus sign,
        // which would otherwise come out the far end as a space.
        guard !words.isEmpty,
              let escaped = words.addingPercentEncoding(withAllowedCharacters: unreserved),
              let base = URL(string: template.replacingOccurrences(of: "%s", with: mark))?.absoluteString
        else { return nil }
        return URL(string: base.replacingOccurrences(of: mark, with: escaped))
    }

    /// Stands in for `%s` while the template is made a URL, so the rest of
    /// it is escaped as an address and the words are escaped as words.
    static let mark = "YABSEARCHWORDS"

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func host(of template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%s"),
              let a = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "a")),
              let b = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "b")),
              let scheme = a.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = a.host, !host.isEmpty, host == b.host
        else { return nil }
        return host.lowercased()
    }
}

/// What the field searches with in one space: its own engine (Space.search,
/// set on the space's page in Settings › Spaces) or, while it has none,
/// Settings › Search's. As in Arc, where each space can search with an
/// engine of its own; site aliases stay the same in every space.
struct EngineChoice: Equatable {
    /// For the engine's search suggestions: `.custom` for a results page of
    /// your own, which suggests nothing.
    let engine: Engine
    /// The results page, with `%s` where the words go.
    let template: String
    /// What the row under the field calls it.
    let name: String

    /// Settings › Search's engine.
    static var global: EngineChoice {
        let engine = Engine.current
        return EngineChoice(engine: engine, template: engine.template(custom: Engine.customTemplate), name: Engine.name)
    }

    /// A space's: `search` is an engine's raw value, Space.search, and
    /// `custom` the results page for Other…. Nil, or Other… without a page
    /// that holds up, is Settings › Search's.
    static func space(_ search: String?, custom: String?) -> EngineChoice {
        guard let own = own(search, custom: custom) else { return .global }
        return own
    }

    /// The space's own engine alone, nil while it uses Settings › Search's.
    static func own(_ search: String?, custom: String?) -> EngineChoice? {
        guard let search, let engine = Engine(rawValue: search) else { return nil }
        guard engine == .custom else { return EngineChoice(engine: engine, template: engine.template(custom: ""), name: engine.title) }
        let page = (custom ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = Engine.host(of: page) else { return nil }
        return EngineChoice(engine: .custom, template: page, name: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    func url(for text: String) -> URL? { Engine.url(for: text, template: template) }

    /// A place if it can be one, a search with this engine if it can't.
    func destination(for typed: String) -> URL? { Address.url(from: typed) ?? url(for: typed) }
}
