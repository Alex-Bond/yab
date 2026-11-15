import Foundation
import Testing
@testable import Fast

/// Register 2668: a site search's alias, then Space, starts that site's
/// search in the field, as Chromium's "Space or Tab" (its default) does;
/// "Tab" keeps Tab alone. The cases are Chromium's own
/// (OmniboxEditModel::ShouldAcceptKeywordAfterInsertingSpaceAtEnd and
/// ShouldAcceptKeywordAfterInsertingSpaceInMiddle, ClearKeyword).
@MainActor @Suite(.serialized)
struct SiteSearchSpaceTests {
    private func isolated(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "site-search-space-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try Scopes.withSitesForTesting(defaults) { try body(defaults) }
    }

    /// What a space typed at the end of these words starts: the site's id
    /// and its words, or nil.
    private func atEnd(_ words: String) -> String? {
        let new = words + " "
        return Scopes.spaced(from: words, to: new, caret: (new as NSString).length).map { $0.scope.id + "|" + $0.words }
    }

    @Test func theWholeAliasThenSpaceStartsItsSite() throws {
        try isolated { _ in
            #expect(Scopes.spaceStarts, "Space or Tab, as Chromium comes")
            #expect(atEnd("yt") == "youtube.com|")
            #expect(atEnd("gh") == "github.com|")
            #expect(atEnd("YT") == "youtube.com|", "an alias is kept lowercased; typed in capitals it is the same alias")
            let ideographic = "yt\u{3000}"
            #expect(Scopes.spaced(from: "yt", to: ideographic, caret: (ideographic as NSString).length)?.scope.id == "youtube.com",
                    "an input method's wide space, as Chromium takes it")
        }
    }

    /// Only an alias. A site's name or host, which Tab also takes, and a
    /// part of an alias stay words, as Chromium enters on a keyword alone:
    /// "youtube cats" is a search.
    @Test func aNameAHostOrAPartOfAnAliasStaysWords() throws {
        try isolated { _ in
            #expect(atEnd("youtube") == nil)
            #expect(atEnd("youtube.com") == nil)
            #expect(atEnd("y") == nil)
            #expect(atEnd("sto") == nil)
            #expect(atEnd("ytx") == nil)
            #expect(atEnd("go yt") == nil, "an alias after other words")
            #expect(atEnd(" yt") == nil, "space before the alias")
            #expect(atEnd("yt ") == nil, "a second space")
            #expect(Scopes.spaced(from: "yt", to: "yt", caret: 2) == nil, "nothing changed")
            #expect(Scopes.spaced(from: "yt", to: "ytx", caret: 3) == nil, "not a space")
        }
    }

    /// A space put in right after an alias that begins the words: the site,
    /// the rest of the words in its field.
    @Test func aSpacePutInAfterTheAliasTakesTheWordsBehindIt() throws {
        try isolated { _ in
            let hit = Scopes.spaced(from: "ytcats", to: "yt cats", caret: 3)
            #expect(hit?.scope.id == "youtube.com" && hit?.words == "cats")
            #expect(Scopes.spaced(from: "xxcats", to: "yt cats", caret: 3) == nil, "the words before the space changed")
            #expect(Scopes.spaced(from: "youtubecats", to: "youtube cats", caret: 8) == nil, "a name, not an alias")
            #expect(Scopes.spaced(from: "go ytcats", to: "go yt cats", caret: 6) == nil, "more than one word before it")
        }
    }

    @Test func tabAloneKeepsSpaceAsWords() throws {
        try isolated { defaults in
            defaults.set(false, forKey: Scopes.spaceKey)
            #expect(!Scopes.spaceStarts)
            #expect(atEnd("yt") == nil)
            #expect(Scopes.spaced(from: "ytcats", to: "yt cats", caret: 3) == nil)
            // What Tab offers is not this setting's.
            #expect(Scopes.offer(for: "yt", ending: nil)?.id == "youtube.com")
        }
    }

    @Test func aSiteOfYourOwnAndASiteTurnedOff() throws {
        try isolated { _ in
            let token = UUID().uuidString.lowercased().prefix(6)
            let own = try #require(Scopes.add(name: "Logs", template: "https://tools-\(token).invalid/logs?id=%s", keyword: "lg\(token)"))
            #expect(atEnd("lg\(token)") == own.id + "|")
            let youtube = try #require(Scopes.all.first { $0.id == "youtube.com" })
            Scopes.set(youtube, on: false)
            defer { Scopes.set(youtube, on: true) }
            #expect(atEnd("yt") == nil, "a site that is off answers to nothing")
        }
    }

    /// The field: Space after "yt" is YouTube's field, empty; ⌫ there gives
    /// back "yt " and the words typed on from it stay words, as Chromium's
    /// ClearKeyword puts the keyword and its space back. Not in a place of
    /// the field's own.
    @Test func theFieldEntersAndGivesTheAliasAndSpaceBack() throws {
        try isolated { _ in
            let browser = Browser(windowID: UUID())
            defer { browser.dismiss() }
            browser.newTab()
            browser.typed = "yt"
            #expect(browser.enterScope(spacing: "yt", to: "yt ", caret: 3))
            #expect(browser.query.scope?.id == "youtube.com")
            #expect(browser.typed == "")
            browser.typed = "cats"
            #expect(browser.offers.first?.url?.absoluteString == "https://www.youtube.com/results?search_query=cats")
            browser.typed = ""
            #expect(browser.leaveScope(restoring: true))
            #expect(browser.query.scope == nil && browser.typed == "yt ")
            browser.typed = "yt c"
            #expect(!browser.enterScope(spacing: "yt c", to: "yt c ", caret: 5), "words typed on stay words")

            browser.typed = "ytcats"
            #expect(browser.enterScope(spacing: "ytcats", to: "yt cats", caret: 3))
            #expect(browser.query.scope?.id == "youtube.com" && browser.typed == "cats")
            browser.leaveScope()
            browser.typed = ""

            browser.query.place = .history
            defer { browser.query.place = nil }
            #expect(!browser.enterScope(spacing: "yt", to: "yt ", caret: 3), "History's field searches History")
            #expect(browser.query.scope == nil)
        }
    }
}
