import UIKit

/// The engine's own completions for the words typed: asked 120 ms after the last key, never in test runs. The rows take
/// them only while they still start with the words.
@MainActor
@Observable
final class SearchSuggest {
    static let shared = SearchSuggest()

    /// The words the phrases were asked for, and the engine's phrases for them.
    private(set) var asked = ""
    private(set) var phrases: [String] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored private let fetch: (URL) async throws -> Data

    init(enabled: @escaping () -> Bool = { !LaunchOptions.current.isTestRun },
         fetch: @escaping (URL) async throws -> Data = { (try await SearchSuggest.session.data(from: $0)).0 }) {
        self.enabled = enabled; self.fetch = fetch
    }

    /// No cookies: typing in the field is not a visit to the engine.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 1.5
        return URLSession(configuration: config)
    }()

    @discardableResult
    func ask(_ text: String, engine: SearchEngine, local: Bool = false) -> Task<Void, Never>? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !local, !words.contains("://"), enabled(),
              let url = Self.url(for: words, engine: engine, languages: Self.languages) else {
            asked = words
            phrases = []
            return nil
        }
        let fetch = self.fetch
        let work = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let data = try? await fetch(url), !Task.isCancelled else { return }
            self?.asked = words
            self?.phrases = Self.parse(data)
        }
        task = work
        return work
    }

    /// The phone's languages, then its keyboards'.
    private static var languages: [String] {
        Locale.preferredLanguages + UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
    }

    /// The address that asks this engine, the Mac's own (SearchSuggestions).
    /// Google's chrome-omni client is the one that fixes spelling, misspelled
    /// non-Latin words included; its firefox client answers such words with nothing.
    nonisolated static func url(for words: String, engine: SearchEngine, languages: [String]) -> URL? {
        guard !words.isEmpty else { return nil }
        let base: String
        var fields: [URLQueryItem]
        switch engine {
        case .google:
            base = "https://www.google.com/complete/search"
            fields = [URLQueryItem(name: "client", value: "chrome-omni"),
                      URLQueryItem(name: "gs_ri", value: "chrome-ext-ansg"),
                      URLQueryItem(name: "xssi", value: "t"),
                      URLQueryItem(name: "ie", value: "UTF-8"), URLQueryItem(name: "oe", value: "UTF-8"),
                      URLQueryItem(name: "hl", value: language(of: words, in: languages)),
                      URLQueryItem(name: "q", value: words)]
        case .duckduckgo:
            base = "https://duckduckgo.com/ac/"
            fields = [URLQueryItem(name: "type", value: "list"), URLQueryItem(name: "q", value: words)]
        case .bing:
            base = "https://api.bing.com/osjson.aspx"
            fields = [URLQueryItem(name: "query", value: words)]
        case .ecosia:
            base = "https://ac.ecosia.org/autocomplete"
            fields = [URLQueryItem(name: "type", value: "list"), URLQueryItem(name: "q", value: words)]
        case .startpage:
            base = "https://www.startpage.com/osuggestions"
            fields = [URLQueryItem(name: "q", value: words)]
        case .kagi:
            base = "https://kagi.com/api/autosuggest"
            fields = [URLQueryItem(name: "q", value: words)]
        case .brave:
            base = "https://search.brave.com/api/suggest"
            fields = [URLQueryItem(name: "q", value: words)]
        case .qwant:
            base = "https://api.qwant.com/v3/suggest"
            fields = [URLQueryItem(name: "q", value: words)]
        case .custom: return nil
        }
        var parts = URLComponents(string: base)!
        parts.queryItems = fields
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    /// The first language whose alphabet spells the words: Russian words on an
    /// English iPhone with a Russian keyboard are corrected as Russian, not
    /// into English names.
    nonisolated static func language(of words: String, in languages: [String]) -> String {
        let letters = words.lowercased().unicodeScalars.filter(CharacterSet.letters.contains)
        return languages.first { language in
            guard let alphabet = Locale(identifier: language).exemplarCharacterSet else { return false }
            return letters.allSatisfy(alphabet.contains)
        } ?? languages.first ?? "en"
    }

    /// The phrases of an answer: never the sites Google mixes in.
    nonisolated static func parse(_ data: Data) -> [String] {
        let clean = data.starts(with: [41, 93, 125, 39]) ? Data(data.dropFirst(4)) : data
        guard let json = try? JSONSerialization.jsonObject(with: clean) else { return [] }
        if let root = json as? [String: Any], let body = root["data"] as? [String: Any],
           let items = body["items"] as? [[String: Any]] {
            return items.compactMap { $0["value"] as? String }
        }
        guard let root = json as? [Any], root.count > 1, let list = root[1] as? [String] else { return [] }
        let kinds = (root.count > 4 ? root[4] as? [String: Any] : nil)?["google:suggesttype"] as? [String] ?? []
        return list.enumerated().filter { !(kinds.indices.contains($0.offset) && kinds[$0.offset].hasPrefix("NAVIGATION")) }.map(\.element)
    }

    /// Up to three phrases for these words, the words themselves left out.
    /// Asked for exactly these words, the engine's phrases stand as they are,
    /// spelling fixed ("communs" → "communes"); asked for earlier words,
    /// only those that still start with what is typed.
    func phrases(for text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = typed.lowercased()
        guard !words.isEmpty else { return [] }
        let current = asked == typed
        return Array(phrases.filter { (current || $0.lowercased().hasPrefix(words)) && $0.lowercased() != words }.prefix(3))
    }
}
