import Foundation
import Testing
@testable import Fast

struct SearchSuggestionsTests {
    private func data(_ json: Any) throws -> Data { try JSONSerialization.data(withJSONObject: json) }

    private func row(_ key: String, _ kind: Suggestion.Kind) -> Suggestion {
        Suggestion(key: key, title: "", url: URL(string: "https://" + key.replacingOccurrences(of: " ", with: "-")), kind: kind)
    }

    private func suggestions(_ count: Int) -> [Suggestion] {
        (1...count).map { row("cloudflare \($0)", .suggested) }
    }

    @MainActor @Test func historyAndAskComeBeforeAFewSuggestions() {
        // #108: "cloudflare" listed ten completions before Ask and the
        // dashboard the user goes to.
        let list = [row("cloudflare", .search), row("Ask", .ask), row("Task", .task),
                    row("dash.cloudflare.com", .visited), row("developers.cloudflare.com", .visited)]
        let merged = SearchSuggestions.merge(suggestions(10), into: list, lead: 0)
        #expect(merged.list.map(\.key) == ["cloudflare", "Ask", "Task", "dash.cloudflare.com", "developers.cloudflare.com",
                                           "cloudflare 1", "cloudflare 2", "cloudflare 3", "cloudflare 4"])
        #expect(merged.lead == 0)
    }

    @MainActor @Test func pagesBeyondTheFirstFewFollowTheSuggestions() {
        let list = [row("git", .search), row("Ask", .ask), row("Task", .task),
                    row("github.com", .open), row("gitlab.com", .visited), row("git-scm.com", .visited),
                    row("gitea.com", .visited), row("Settings", .setting(.search))]
        let merged = SearchSuggestions.merge(suggestions(6), into: list, lead: 0)
        #expect(merged.list.map(\.kind) == [.search, .ask, .task, .open, .visited, .visited, .visited,
                                            .suggested, .suggested, .suggested, .suggested, .setting(.search)])
    }

    @MainActor @Test func anotherSpacesOpenTabsComeBeforeTheSuggestions() {
        // #260a: this space's tabs, the places, other spaces' tabs, then search.
        let list = [row("board", .search), row("Ask", .ask), row("Task", .task),
                    row("design.board", .open), row("a.board", .visited), row("b.board", .visited),
                    row("c.board", .visited), row("work.board", .open), row("d.board", .visited)]
        let merged = SearchSuggestions.merge(suggestions(4), into: list, lead: 0)
        #expect(merged.list.map(\.key) == ["board", "Ask", "Task", "design.board", "a.board", "b.board", "c.board",
                                           "work.board", "cloudflare 1", "cloudflare 2", "cloudflare 3", "cloudflare 4",
                                           "d.board"])
    }

    @MainActor @Test func aQuestionKeepsAskOnTop() {
        // #103: Ask, chosen for a question, went down under the completions.
        let list = [row("who won", .ask), row("who won", .search), row("Task", .task), row("whowon.com", .visited)]
        let merged = SearchSuggestions.merge(suggestions(8), into: list, lead: 0)
        #expect(merged.list.first?.kind == .ask)
        #expect(merged.lead == 0)
        #expect(merged.list.map(\.kind) == [.ask, .search, .task, .visited, .suggested, .suggested, .suggested, .suggested])
    }

    @MainActor @Test func aPlaceReturnTakesStaysChosen() {
        let list = [row("mygo.dev", .visited), row("mygo", .search), row("Ask", .ask), row("Task", .task),
                    row("github.com/egoist/mygo", .visited)]
        let merged = SearchSuggestions.merge(suggestions(5), into: list, lead: 0)
        #expect(merged.list.map(\.key).prefix(5) == ["mygo.dev", "mygo", "Ask", "Task", "github.com/egoist/mygo"])
        #expect(merged.list.filter { $0.kind == .suggested }.count == SearchSuggestions.shown)
        #expect(merged.lead == 0)
    }

    @MainActor @Test func noSearchRowOrNoSuggestionsLeavesTheList() {
        let plain = [row("dash.cloudflare.com", .visited)]
        #expect(SearchSuggestions.merge(suggestions(3), into: plain, lead: 0).list == plain)
        let searched = [row("q", .search), row("q.com", .visited)]
        #expect(SearchSuggestions.merge([], into: searched, lead: 0).list == searched)
    }

    @MainActor @Test func shortWordsWithoutAgentRowsStillGetPlacesFirst() {
        let list = [row("cl", .search), row("claude.ai", .visited)]
        let merged = SearchSuggestions.merge(suggestions(2), into: list, lead: 0)
        #expect(merged.list.map(\.key) == ["cl", "claude.ai", "cloudflare 1", "cloudflare 2"])
    }

    @MainActor @Test func pastSearchesTheEngineRepeatsAreListedOnce() {
        let list = [row("gma", .search), row("Ask", .ask), row("gmail login", .asked)]
        let merged = SearchSuggestions.merge([row("gmail login", .suggested)], into: list, lead: 0)
        #expect(merged.list.map(\.kind) == [.search, .ask, .suggested])
    }

    @Test func entityNamesNavigationDuplicatesAndLimit() throws {
        let name = "Jürgen Klopp"
        let encoded = Data([58, UInt8(name.utf8.count)] + Array(name.utf8)).base64EncodedString()
        let root: [Any] = ["jürg", ["jürg", "jürgen klopp", "Jürgen Klopp", "example.com", "one", "two", "three", "four"], [], [],
            ["google:suggesttype": ["QUERY", "ENTITY", "QUERY", "NAVIGATION", "QUERY", "QUERY", "QUERY", "QUERY"],
             "google:suggestdetail": [[:], ["google:entityinfo": encoded]]]]
        let response = Data(")]}'\n".utf8) + (try data(root))
        #expect(SearchSuggestions.parse(response, engine: .google, typed: "jürg") == [name, "one", "two", "three", "four"])
    }

    /// Google's answer for "twitter" as the branch fix/suggestion-remove
    /// saw it (2026-11-08): http://twitter.com, a NAVIGATION result, third
    /// by relevance.
    static let twitter = #")]}'\#n["twitter",["twitter downloader","twitter viewer","http://twitter.com","twitter x","twitter login"],["","","","",""],[],{"google:suggestrelevance":[602,601,600,561,560],"google:suggesttype":["QUERY","QUERY","NAVIGATION","QUERY","QUERY"],"google:verbatimrelevance":1300}]"#
    /// Google's answer for "github", live 2026-11-08 (client=chrome-omni).
    static let github = #")]}'\#n["github",["github login","https://github.com/","github copilot","github desktop","github down"],["","How people build software · GitHub","","",""],[],{"google:suggestrelevance":[800,799,601,600,553],"google:suggesttype":["QUERY","NAVIGATION","QUERY","QUERY","QUERY"],"google:verbatimrelevance":1300}]"#

    /// Google's answer for "faceb", live 2026-11-08: facebook.com scored
    /// above the words themselves (1150 against 851), which Chrome 157 still
    /// lists last and never finishes inline.
    static let faceb = #")]}'\#n["faceb",["facebook","https://www.facebook.com/","facebook login","facebook marketplace"],["","Facebook - Log In or Sign Up","",""],[],{"google:suggestrelevance":[1250,1150,601,600],"google:suggesttype":["QUERY","NAVIGATION","QUERY","QUERY"],"google:verbatimrelevance":851}]"#

    @Test func navigationIsASiteRankedByRelevance() throws {
        let items = SearchSuggestions.read(Data(Self.twitter.utf8), engine: .google, typed: "twitter")
        #expect(items == [.words("twitter downloader"), .words("twitter viewer"),
                          .site(URL(string: "https://twitter.com")!, title: ""), .words("twitter x"), .words("twitter login")])
        // The words alone never search for an address.
        #expect(SearchSuggestions.parse(Data(Self.twitter.utf8), engine: .google, typed: "twitter")
                == ["twitter downloader", "twitter viewer", "twitter x", "twitter login"])
        let github = SearchSuggestions.read(Data(Self.github.utf8), engine: .google, typed: "github")
        #expect(github.prefix(2) == [.words("github login"), .site(URL(string: "https://github.com/")!, title: "How people build software · GitHub")])
        // Out of order, the relevance decides, as in Chromium's SearchProvider.
        let shuffled: [Any] = ["yout", ["youtube tv", "https://www.youtube.com/", "youtube"], ["", "YouTube", ""], [],
                               ["google:suggesttype": ["QUERY", "NAVIGATION", "QUERY"], "google:suggestrelevance": [700, 1150, 1250],
                                "google:verbatimrelevance": 851]]
        #expect(SearchSuggestions.read(try data(shuffled), engine: .google, typed: "yout")
                == [.words("youtube"), .site(URL(string: "https://www.youtube.com/")!, title: "YouTube"), .words("youtube tv")])
    }

    @Test func onlyPlainWebAddressesBecomeSites() throws {
        let bad = ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com", "https://user:pw@example.com/",
                   "https://example.com:8443/", "https://localhost/", "example.com", "https://.com/", "data:text/html,hi"]
        for text in bad { #expect(SearchSuggestions.site(text) == nil, "\(text)") }
        #expect(SearchSuggestions.site("http://twitter.com")?.absoluteString == "https://twitter.com")
        #expect(SearchSuggestions.site("https://www.Amazon.com/")?.absoluteString == "https://www.amazon.com/")
        let root: [Any] = ["x", bad + ["https://x.com/", "http://x.com"], [], [],
                           ["google:suggesttype": Array(repeating: "NAVIGATION", count: bad.count + 2)]]
        #expect(SearchSuggestions.read(try data(root), engine: .google, typed: "x") == [.site(URL(string: "https://x.com/")!, title: "")])
    }

    @MainActor @Test func aSiteRowSitsAmongTheWordsUnderReturnsRow() {
        let items = SearchSuggestions.read(Data(Self.twitter.utf8), engine: .google, typed: "twitter")
        let rows = SearchSuggestions.rows(items) { URL(string: "https://www.google.com/search?q=" + $0.replacingOccurrences(of: " ", with: "+")) }
        let list = [row("twitter", .search), row("Ask", .ask), row("x.com", .visited)]
        let merged = SearchSuggestions.merge(rows, into: list, lead: 0)
        // Under the engine's words, as Chromium 157 lists it.
        #expect(merged.list.map(\.key) == ["twitter", "Ask", "x.com", "twitter downloader", "twitter viewer", "twitter x", "twitter login", "twitter.com"])
        let site = merged.list[7]
        #expect(site.kind == .known && site.engine && site.url?.absoluteString == "https://twitter.com" && site.isPlace)
        #expect(merged.lead == 0)
    }

    @MainActor @Test func aSiteAlreadyListedByItsAddressIsListedOnce() {
        let github = SearchSuggestions.rows(SearchSuggestions.read(Data(Self.github.utf8), engine: .google, typed: "github")) {
            URL(string: "https://www.google.com/search?q=" + $0)
        }
        // The same destination, however written: listed once, as Chromium's
        // AutocompleteResult dedupes by stripped URL.
        for place in [row("github.com", .known), row("www.github.com", .open), row("github.com", .visited),
                      Suggestion(key: "GitHub", title: "", url: URL(string: "http://www.github.com/#top"), kind: .quickAction("gh"))] {
            let merged = SearchSuggestions.merge(github, into: [row("github", .search), place], lead: 0)
            #expect(!merged.list.contains { $0.engine }, "\(place.key)")
            #expect(merged.list.filter { $0.kind == .suggested }.count == SearchSuggestions.shown)
        }
        // Another page of the same site is another destination: both stay.
        for place in [row("github.com/example/project", .visited), row("gitlab.com", .visited)] {
            let merged = SearchSuggestions.merge(github, into: [row("github", .search), place], lead: 0)
            #expect(merged.list.map(\.key) == ["github", place.key, "github login", "github copilot", "github desktop", "github down", "github.com"])
        }
    }

    @Test func strippedAddressesAreChromes() {
        let same = ["https://www.facebook.com/", "http://facebook.com", "https://facebook.com/#x", "HTTPS://WWW.FACEBOOK.COM"]
        #expect(Set(same.map { SearchSuggestions.stripped(URL(string: $0)!) }) == ["facebook.com/"])
        #expect(SearchSuggestions.stripped(URL(string: "https://facebook.com/login?next=1")!) == "facebook.com/login?next=1")
        #expect(SearchSuggestions.stripped(URL(string: "https://m.facebook.com/")!) == "m.facebook.com/")
    }

    @MainActor @Test func aSiteStaysWhileItsAddressIsStillBeingTyped() {
        let site = SearchSuggestions.Item.site(URL(string: "https://www.facebook.com/")!, title: "Facebook")
        #expect(site.completes("faceb"))
        #expect(site.completes("facebook.c"))
        #expect(!site.completes("facebook.com"))
        #expect(!site.completes("facex"))
    }

    @Test func tenSuggestionsAreKeptAndLongResponsesAreBounded() throws {
        let words = (1...24).map { "query \($0)" }
        let ten: [Any] = ["query", Array(words.prefix(10))]
        let long: [Any] = ["query", words]
        #expect(SearchSuggestions.parse(try data(ten), engine: .google, typed: "query") == Array(words.prefix(10)))
        #expect(SearchSuggestions.parse(try data(long), engine: .google, typed: "query") == Array(words.prefix(20)))
    }

    @Test func malformedEntityFallsBackToSearchWords() throws {
        for encoded in ["!", "Og==", "Ov///////////wE=", "AA=="] {
            let root: [Any] = ["q", ["query"], [], [], ["google:suggestdetail": [["google:entityinfo": encoded]]]]
            #expect(SearchSuggestions.parse(try data(root), engine: .google, typed: "q") == ["query"])
        }
    }

    @Test func openSearchAndQwant() throws {
        let response: [Any] = ["gma", ["gma", " Gmail ", "GMAIL", "gmail login", ""]]
        for engine in [Engine.duckduckgo, .bing, .ecosia, .startpage, .kagi, .brave] {
            #expect(SearchSuggestions.parse(try data(response), engine: engine, typed: "gma") == ["Gmail", "gmail login"])
        }
        let qwant = ["data": ["items": [["value": "gmail"], ["value": "gmail login"]]]]
        #expect(SearchSuggestions.parse(try data(qwant), engine: .qwant, typed: "gma") == ["gmail", "gmail login"])
    }

    @Test func brokenResponsesLeaveNoSuggestions() {
        for raw in ["", "[]", "{}", "[1,null]", "<html>bad gateway</html>"] {
            #expect(SearchSuggestions.parse(Data(raw.utf8), engine: .google, typed: "q").isEmpty)
        }
    }

    @Test func requestsEncodeWordsAndLanguageWithoutCookies() throws {
        for engine in Engine.allCases where engine != .custom {
            let request = try #require(SearchSuggestions.request("a+b & español", engine: engine, language: "es"))
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.scheme == "https")
            #expect(components.percentEncodedQuery?.contains("a%2Bb") == true)
            #expect(components.queryItems?.contains { $0.value == "a+b & español" } == true)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "es")
            if engine == .google {
                #expect(components.queryItems?.contains(URLQueryItem(name: "hl", value: "es")) == true)
                #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/") == true)
            }
        }
        #expect(SearchSuggestions.request("query", engine: .custom, language: "en") == nil)
    }

    @MainActor @Test func cancellingBeforeDebounceDropsCallback() async throws {
        let suggestions = SearchSuggestions()
        var callbacks = 0
        suggestions.update("query", engine: .google) { callbacks += 1 }
        suggestions.update(nil, engine: .google) { callbacks += 1 }
        try await Task.sleep(for: .milliseconds(250))
        #expect(suggestions.words.isEmpty)
        #expect(callbacks == 0)
    }
}
