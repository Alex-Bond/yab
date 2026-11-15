import Foundation
import Testing
@testable import Fast

/// Manual Add Site must publish the fields just entered, even when it
/// replaces a custom site that already has an edited search address. Since
/// #2027 a site is replaced only by the same search (its address), not by
/// another on its host: SiteSearchSameHostTests.
@MainActor @Suite(.serialized)
struct CustomSiteReplacementTests {
    private func isolated(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "custom-site-replacement-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = UUID().uuidString.lowercased()
        try Scopes.withSitesForTesting(defaults) { try body(defaults, token) }
    }

    private func effective(_ id: String) throws -> Scope {
        let matches = Scopes.all.filter { $0.id == id }
        #expect(matches.count == 1, "replacing the same search remains one custom site")
        return try #require(matches.first)
    }

    @Test(arguments: ["", "replacement"])
    func replacingAnEditedSiteUsesTheNewAddressAndKeyword(keyword: String) throws {
        try isolated { defaults, token in
            let host = "manual-" + token + ".invalid"
            let original = try #require(Scopes.add(name: "Alpha", template: "https://\(host)/first?q=%s",
                                                   keyword: "old-" + token))
            Scopes.setTemplate("https://\(host)/edited?q=%s", for: original)
            #expect(try effective(original.id).template == "https://\(host)/edited?q=%s")
            let enteredKeyword = keyword.isEmpty ? "" : "  REPLACEMENT-\(token)  "
            // Added again at the address it now searches: the same search.
            let replacement = try #require(Scopes.add(name: "  Beta  ",
                template: "https://\(host)/edited?q=%s", keyword: enteredKeyword))

            let saved = try effective(original.id)
            #expect(replacement.id == original.id && saved.id == original.id && saved.host == host)
            #expect(Scopes.all.filter { $0.own == true && $0.host == host }.count == 1)
            #expect(saved.own == true && saved.name == "Beta")
            #expect(saved.template == "https://\(host)/edited?q=%s")
            #expect(saved.url(for: "two words")?.absoluteString == "https://\(host)/edited?q=two%20words")
            #expect(saved.aliases == (keyword.isEmpty ? [] : ["replacement-" + token]))
            #expect((defaults.dictionary(forKey: Scopes.templatesKey) as? [String: String])?[original.id] == nil)
            #expect((defaults.dictionary(forKey: Scopes.keywordsKey) as? [String: String])?[original.id]
                    == (keyword.isEmpty ? "" : "replacement-" + token))
        }
    }

    @Test func replacingOneSitePreservesOtherSitesAndOverrides() throws {
        try isolated { defaults, token in
            let firstHost = "first-" + token + ".invalid", secondHost = "second-" + token + ".invalid"
            let first = try #require(Scopes.add(name: "First", template: "https://\(firstHost)/a?q=%s",
                                                keyword: "first-" + token))
            let second = try #require(Scopes.add(name: "Second", template: "https://\(secondHost)/b?q=%s",
                                                 keyword: "second-" + token))
            Scopes.setTemplate("https://\(firstHost)/edited?q=%s", for: first)
            Scopes.setTemplate("https://\(secondHost)/keep?q=%s", for: second)
            let other = try effective(second.id)
            let before = Scopes.all.filter { $0.id != first.id }
            defaults.set("keep", forKey: "unrelated.fixture.value")

            _ = try #require(Scopes.add(name: "Replaced", template: "https://\(firstHost)/edited?q=%s", keyword: ""))

            #expect(try effective(first.id).name == "Replaced")
            #expect(try effective(second.id) == other)
            #expect(Scopes.all.filter { $0.id != first.id } == before)
            #expect((defaults.dictionary(forKey: Scopes.templatesKey) as? [String: String])?[second.id]
                    == "https://\(secondHost)/keep?q=%s")
            #expect((defaults.dictionary(forKey: Scopes.keywordsKey) as? [String: String])?[second.id] == "second-" + token)
            #expect(defaults.string(forKey: "unrelated.fixture.value") == "keep")
        }
    }

    @Test(arguments: ["invalid-address", "invalid-keyword", "taken-keyword"])
    func aRejectedDraftNeverPartiallyReplacesTheSavedSite(reason: String) throws {
        try isolated { defaults, token in
            let host = "saved-" + token + ".invalid", otherHost = "other-" + token + ".invalid"
            let first = try #require(Scopes.add(name: "Saved", template: "https://\(host)/a?q=%s", keyword: "saved-" + token))
            _ = try #require(Scopes.add(name: "Other", template: "https://\(otherHost)/a?q=%s", keyword: "taken-" + token))
            Scopes.setTemplate("https://\(host)/keep?q=%s", for: first)
            let before = Scopes.all
            let keywords = defaults.dictionary(forKey: Scopes.keywordsKey) as? [String: String]
            let templates = defaults.dictionary(forKey: Scopes.templatesKey) as? [String: String]
            let template = reason == "invalid-address" ? "https://\(host)/missing-placeholder" : "https://\(host)/new?q=%s"
            let keyword = reason == "invalid-keyword" ? "invalid/alias" : reason == "taken-keyword" ? "taken-" + token : ""

            #expect(Scopes.add(name: "Should not replace", template: template, keyword: keyword) == nil)
            #expect(Scopes.all == before)
            #expect(defaults.dictionary(forKey: Scopes.keywordsKey) as? [String: String] == keywords)
            #expect(defaults.dictionary(forKey: Scopes.templatesKey) as? [String: String] == templates)
        }
    }

    @Test func anAddressEditStillOverridesTheNewManualBase() throws {
        try isolated { _, token in
            let host = "editing-" + token + ".invalid"
            let scope = try #require(Scopes.add(name: "Editing", template: "https://\(host)/base?q=%s", keyword: ""))
            Scopes.setTemplate("https://\(host)/changed?q=%s", for: scope)
            #expect(try effective(scope.id).template == "https://\(host)/changed?q=%s")
            Scopes.setTemplate(scope.template, for: scope)
            #expect(try effective(scope.id).template == scope.template)
        }
    }

    @Test(arguments: ["unchanged", "dirty", "blank", "rejected"])
    func inlineSubmissionUsesTheCurrentReplacementUnlessActuallyEdited(change: String) throws {
        try isolated { _, token in
            let host = "inline-" + token + ".invalid"
            let old = "old-" + token, replacement = "replacement-" + token
            _ = try #require(Scopes.add(name: "Before", template: "https://\(host)/first?q=%s", keyword: old))
            // This is the field's last projected/submitted value when an
            // Add Site operation replaces the same search underneath it.
            let savedWord = old
            let scope = try #require(Scopes.add(name: "After", template: "https://\(host)/first?q=%s", keyword: replacement))
            let current = try #require(effective(scope.id).aliases.first)
            let word = change == "dirty" ? "  DIRTY-\(token)  "
                : change == "blank" ? "" : change == "rejected" ? "invalid/alias" : old
            // The production SiteRow.commit decision is shared by Return
            // and blur. No second, mirrored draft algorithm is exercised.
            let proposed = SiteAliasCommit.value(word, saved: savedWord, current: current)
            if change == "unchanged" { #expect(proposed == replacement) }
            if change == "rejected" { #expect(Scopes.aliasProblem(proposed, for: scope) != nil) }
            Scopes.setKeyword(proposed, for: scope)

            let expected = change == "dirty" ? ["dirty-" + token] : change == "blank" ? [] : [replacement]
            #expect(try effective(scope.id).aliases == expected)
            #expect(try effective(scope.id).template == "https://\(host)/first?q=%s")
        }
    }

    @Test func aThrowingFixtureRestoresThePreviousSitesAndCaches() throws {
        enum Exit: Error { case expected }
        let before = Scopes.all, on = Scopes.on
        #expect(throws: Exit.self) {
            try isolated { _, token in
                _ = try #require(Scopes.add(name: "Temporary", template: "https://fixture-\(token).invalid/?q=%s", keyword: ""))
                throw Exit.expected
            }
        }
        #expect(Scopes.all == before)
        #expect(Scopes.on == on)
    }
}
