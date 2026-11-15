import Foundation
import Testing
@testable import Fast

struct LiveGitHubFilterTests {
    @Test func personalFiltersAreOptionalAndUseTheExistingSearchContract() throws {
        #expect(LiveGitHub.lists.map(\.id).contains("author"))
        #expect(LiveGitHub.lists.map(\.id).contains("assignee"))
        #expect(!LiveGitHub.shownAtFirst.contains("author"))
        #expect(!LiveGitHub.shownAtFirst.contains("assignee"))
        for list in ["author", "assignee"] {
            let query = try #require(LiveGitHub.personalQuery(list))
            #expect(query == "is:pr is:open archived:false \(list):@me")
            let live = Live(source: "github.search", host: "git.example.test", show: [], query: query)
            let url = try #require(LiveIssues.searchPage(live))
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.host == "git.example.test" && parts.path == "/search")
            #expect(parts.queryItems?.first { $0.name == "q" }?.value == query)
            #expect(parts.queryItems?.first { $0.name == "type" }?.value == "pullrequests")
            let data = try JSONEncoder().encode(Live(show: [list]))
            #expect(try JSONDecoder().decode(Live.self, from: data).show == [list])
        }
        #expect(LiveGitHub.personalQuery("review-requested") == nil)
        #expect(LiveGitHub.personalQuery("author:someone-else") == nil)
    }

    @Test func personalResultsDeduplicateAndKeepInboxStatusAndHiddenRepositories() {
        let url = URL(string: "https://github.com/acme/yab/pull/12")!
        let pull = LiveGitHub.Pull(id: "PR_public_fixture", number: 12, title: "Fix wake", url: url,
                                  repo: "acme/yab", category: nil, draft: false, read: true, updated: nil)
        let own = LiveItem(key: "github.com/acme/yab/pull/12", url: url, title: "Fix wake", group: "acme/yab", words: nil, updated: nil)
        let other = LiveItem(key: "github.com/acme/yab/pull/13", url: URL(string: "https://github.com/acme/yab/pull/13")!,
                             title: "Assigned", group: "acme/yab", words: nil, updated: nil)
        let hidden = LiveItem(key: "github.com/acme/hidden/pull/14", url: URL(string: "https://github.com/acme/hidden/pull/14")!,
                              title: "Hidden", group: "acme/hidden", words: nil, updated: nil)
        let issue = LiveItem(key: "github.com/acme/yab/issues/15", url: URL(string: "https://github.com/acme/yab/issues/15")!,
                             title: "Not a PR", group: "acme/yab", words: nil, updated: nil)
        let items = LiveGitHub.items([("review-requested", [pull])], statuses: [:], hiddenGroups: ["acme/hidden"],
                                    personal: [own, own, other, other, hidden, issue])
        #expect(items.map(\.key) == [own.key, other.key])
        #expect(items.first?.words == .review)
        let only = LiveGitHub.items([], statuses: [:], hiddenGroups: [], personal: [own, other, own])
        #expect(only.map(\.key) == [own.key, other.key])
        #expect(LiveGitHub.items([], statuses: [:], hiddenGroups: [], personal: []).isEmpty)
    }
}
