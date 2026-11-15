import Foundation

// An extension's own search engine (`chrome_settings_overrides.search_provider`
// in its manifest: ChatGPT search's ChatGPT, DuckDuckGo's DuckDuckGo). Chrome
// switches the default engine to it on install and asks "Change back?" at the
// first search; Yab changes nothing by itself: the engine is one more answer
// under Settings › Search › Search with, and searches with it once picked
// there, as Other… with the extension's results page would.

@available(macOS 15.4, *)
@MainActor
enum ExtensionSearchProviders {
    struct Provider: Hashable {
        let extensionID: String
        let name: String
        /// The results page, `%s` where the words go.
        let template: String
    }

    /// The engine an extension picked in Search with, by its id.
    static let pickedKey = "search.customExtension"
    /// Its name, for the row under the field, read off the main thread.
    static let nameKey = "search.customName"

    /// Every loaded extension's engine whose results page holds up.
    static var all: [Provider] {
        Extensions.here.contexts.compactMap { id, context in
            guard let overrides = context.webExtension.manifest["chrome_settings_overrides"] as? [String: Any],
                  let provider = overrides["search_provider"] as? [String: Any],
                  let url = provider["search_url"] as? String else { return nil }
            let template = url.replacingOccurrences(of: "{searchTerms}", with: "%s")
            guard Engine.accepts(template) else { return nil }
            let name = (provider["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? context.webExtension.displayName ?? "Extension"
            return Provider(extensionID: id, name: name, template: template)
        }
        .sorted { $0.name < $1.name }
    }

    /// Searching with an extension's engine: Other… with its page, and its
    /// name kept for the field.
    static func pick(_ provider: Provider, in prefs: Preferences) {
        Store.settings.set(provider.extensionID, forKey: pickedKey)
        Store.settings.set(provider.name, forKey: nameKey)
        prefs.engineCustom = provider.template
        prefs.engine = .custom
    }

    /// An engine of Yab's own picked again: the extension's is forgotten.
    static func forget() {
        Store.settings.removeObject(forKey: pickedKey)
        Store.settings.removeObject(forKey: nameKey)
    }

    static var picked: String? { Store.settings.string(forKey: pickedKey) }
}
